Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$evidenceHome = $PSScriptRoot
$testPath = 'D:\Codex\projects\统一环境\tests\Test-CodexSafeTreeDeleteHashReuse.ps1'
$stdoutPath = Join-Path $evidenceHome 'test-hash-reuse.stdout.txt'
$stderrPath = Join-Path $evidenceHome 'test-hash-reuse.stderr.txt'
$pwsh = 'D:\Codex\tools\PowerShell\7.6.4\pwsh.exe'

$process = Start-Process -FilePath $pwsh `
    -ArgumentList @('-NoProfile', '-File', $testPath) `
    -Wait -PassThru -NoNewWindow `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath

Write-Output ('exit=' + $process.ExitCode)
if (Test-Path -LiteralPath $stdoutPath) {
    Get-Content -LiteralPath $stdoutPath -Tail 60
}
if (Test-Path -LiteralPath $stderrPath) {
    Write-Output '---stderr---'
    Get-Content -LiteralPath $stderrPath -Tail 60
}
exit $process.ExitCode
