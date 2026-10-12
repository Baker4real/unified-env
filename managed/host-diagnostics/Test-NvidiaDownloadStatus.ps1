#Requires -Version 7.0
[CmdletBinding()]
param([string]$EvidenceRoot = 'D:/agents/run-evidence/nvidia-download-status-tests')
$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$runRoot = Join-Path $EvidenceRoot ([guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($runRoot)
$entry = Join-Path $PSScriptRoot 'Get-NvidiaDownloadStatus.ps1'
$caseDirectory = Join-Path $runRoot 'status'
[void][IO.Directory]::CreateDirectory($caseDirectory)
$downloadPath = Join-Path $caseDirectory 'download.json'
$postPath = Join-Path $caseDirectory 'postprocessing.json'
$fixture = [ordered]@{
    state = 8; percentComplete = 100; downloadSpeed = 0; totalBytes = 1000
    downloadedBytes = 1000; errorCode = 0; httpResponseCode = 206
    version = '617.42'; url = 'https://test.invalid/path?token=SYNTHETIC_PRIVATE_VALUE'
    fileLocation = 'SYNTHETIC_PRIVATE_VALUE'; taskId = 'fixture-1'
}
$fixture | ConvertTo-Json | Set-Content -LiteralPath $downloadPath -Encoding utf8
@{ taskId = 'fixture-1'; status = 1 } | ConvertTo-Json | Set-Content -LiteralPath $postPath -Encoding utf8
$cases = [Collections.Generic.List[object]]::new()
function Check([string]$Name, [scriptblock]$Body) {
    try { & $Body; $cases.Add([pscustomobject]@{name=$Name;passed=$true}) }
    catch { $cases.Add([pscustomobject]@{name=$Name;passed=$false;reason=$_.Exception.Message}) }
}
function Assert([bool]$Condition, [string]$Reason) { if (-not $Condition) { throw $Reason } }
function Run-Diagnostic([switch]$Live, [hashtable]$ProxyOverrides = @{}) {
    $psi = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8; $psi.StandardErrorEncoding = $utf8
    $arguments = @('-NoProfile','-File',$entry,'-StatusDirectory',$caseDirectory)
    if ($Live) { $arguments += '-SkipProcessEnvironment' } else { $arguments += '-Offline' }
    foreach ($arg in $arguments) {
        $psi.ArgumentList.Add($arg)
    }
    foreach ($key in $ProxyOverrides.Keys) { $psi.Environment[$key] = $ProxyOverrides[$key] }
    $child = [Diagnostics.Process]::Start($psi)
    $stdoutTask = $child.StandardOutput.ReadToEndAsync()
    $stderrTask = $child.StandardError.ReadToEndAsync()
    $child.WaitForExit()
    $text = $stdoutTask.GetAwaiter().GetResult()
    $errors = $stderrTask.GetAwaiter().GetResult()
    $exit = $child.ExitCode; $child.Dispose()
    Assert ($exit -eq 0) ('diagnostic-exit-' + $exit)
    Assert (-not $errors.Contains('SYNTHETIC_PRIVATE_VALUE')) 'private-value-in-stderr'
    Assert (-not $text.Contains('SYNTHETIC_PRIVATE_VALUE')) 'private-value-in-stdout'
    Assert ([Text.Encoding]::UTF8.GetByteCount($text) -le 6000) 'output-budget-exceeded'
    return ($text | ConvertFrom-Json -ErrorAction Stop)
}
Check 'completed-download-with-zero-speed-is-not-stalled' {
    $before = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash
    $result = Run-Diagnostic
    Assert ($result.download.assessment -eq 'bytes-complete') 'wrong-completion-assessment'
    Assert ($result.download.integrityVerification -eq 'not-performed') 'false-integrity-claim'
    Assert ($result.postprocessing.sameTask -eq $true) 'postprocessing-task-not-correlated'
    Assert ((Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash -eq $before) 'source-was-modified'
}
Check 'proxy-credentials-and-no-proxy-list-stay-private' {
    $result = Run-Diagnostic -Live -ProxyOverrides @{
        HTTP_PROXY = 'http://testuser:SYNTHETIC_PRIVATE_VALUE@127.0.0.1:17897/private?token=SYNTHETIC_PRIVATE_VALUE'
        HTTPS_PROXY = 'SYNTHETIC_PRIVATE_VALUE'
        NO_PROXY = 'localhost,international-gfe.download.nvidia.com'
    }
    Assert ($result.proxy.process.HTTP_PROXY.host -eq '127.0.0.1') 'proxy-host-missing'
    Assert ($result.proxy.process.HTTP_PROXY.credentialsPresent -eq $true) 'credential-marker-missing'
    Assert ($result.proxy.process.HTTPS_PROXY.status -eq 'unparseable') 'malformed-proxy-not-classified'
    Assert ($result.proxy.process.NO_PROXY.downloadHostCovered -eq $true) 'download-bypass-not-detected'
    Assert ($result.proxy.process.NO_PROXY.otaHostCovered -eq $false) 'unmatched-bypass-claimed'
}
Check 'one-zero-speed-sample-does-not-prove-stall' {
    $fixture.downloadedBytes = 100; $fixture.percentComplete = 10; $fixture.state = 2
    $fixture | ConvertTo-Json | Set-Content -LiteralPath $downloadPath -Encoding utf8
    $result = Run-Diagnostic
    Assert ($result.download.assessment -eq 'no-progress-in-snapshot') 'zero-speed-overclaimed'
}
Check 'native-error-takes-precedence-over-byte-count' {
    $fixture.downloadedBytes = 1000; $fixture.percentComplete = 100; $fixture.errorCode = 102
    $fixture | ConvertTo-Json | Set-Content -LiteralPath $downloadPath -Encoding utf8
    $result = Run-Diagnostic
    Assert ($result.download.assessment -eq 'native-error') 'failed-task-claimed-complete'
}
Check 'stale-postprocessing-is-not-correlated' {
    @{taskId='different-task';status=1} | ConvertTo-Json | Set-Content -LiteralPath $postPath -Encoding utf8
    $result = Run-Diagnostic
    Assert ($result.postprocessing.sameTask -eq $false) 'stale-success-attached-to-new-task'
}
Check 'inconsistent-byte-count-is-rejected' {
    $fixture.errorCode = 0; $fixture.downloadedBytes = 1001
    $fixture | ConvertTo-Json | Set-Content -LiteralPath $downloadPath -Encoding utf8
    $result = Run-Diagnostic
    Assert ($result.download.assessment -eq 'inconsistent-counters') 'impossible-byte-count-accepted'
}
Check 'missing-counters-and-hostile-fields-remain-unknown' {
    @{state='SYNTHETIC_PRIVATE_VALUE';errorCode=0;version='SYNTHETIC_PRIVATE_VALUE'} |
        ConvertTo-Json | Set-Content -LiteralPath $downloadPath -Encoding utf8
    $result = Run-Diagnostic
    Assert ($result.download.assessment -eq 'unknown') 'missing-counter-claimed-complete'
    Assert ($null -eq $result.download.version) 'untrusted-version-echoed'
}
Check 'malformed-json-has-safe-diagnostic' {
    '{"token":"SYNTHETIC_PRIVATE_VALUE",' | Set-Content -LiteralPath $downloadPath -Encoding utf8
    $result = Run-Diagnostic
    Assert ($result.download.sourceStatus -eq 'read-or-parse-failed') 'parse-failure-hidden'
    Assert ($result.download.assessment -eq 'unknown') 'malformed-json-claimed-success'
}
Check 'oversized-input-is-not-read' {
    [IO.File]::WriteAllText($downloadPath,('X' * (1MB + 1)))
    $result = Run-Diagnostic
    Assert ($result.download.sourceStatus -eq 'size-limit') 'input-size-limit-ignored'
}
$report = [pscustomobject]@{passed=(@($cases | Where-Object { -not $_.passed }).Count -eq 0);cases=@($cases);runRoot=$runRoot}
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $runRoot 'result.json') -Encoding utf8
$report | ConvertTo-Json -Depth 6 -Compress
if (-not $report.passed) { exit 1 }
