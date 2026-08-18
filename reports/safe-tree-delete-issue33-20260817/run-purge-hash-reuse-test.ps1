Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$outDir = 'D:\Codex\projects\统一环境\reports\safe-tree-delete-issue33-20260817'
[void][IO.Directory]::CreateDirectory($outDir)
$stdout = Join-Path $outDir 'Test-CodexSafeTreeDeletePurgeHashReuse.stdout.txt'
$stderr = Join-Path $outDir 'Test-CodexSafeTreeDeletePurgeHashReuse.stderr.txt'
$meta = Join-Path $outDir 'Test-CodexSafeTreeDeletePurgeHashReuse.meta.json'
$sw = [Diagnostics.Stopwatch]::StartNew()
& 'D:\Codex\tools\PowerShell\7.6.4\pwsh.exe' -NoProfile -NonInteractive -File 'D:\Codex\projects\统一环境\tests\Test-CodexSafeTreeDeletePurgeHashReuse.ps1' 1> $stdout 2> $stderr
$code = $LASTEXITCODE
$sw.Stop()
[pscustomobject][ordered]@{
    artifactType = 'env-governance.codex-safe-tree-delete-issue33-test-meta'
    suite = 'Test-CodexSafeTreeDeletePurgeHashReuse'
    exitCode = [int]$code
    elapsedMs = [long]$sw.ElapsedMilliseconds
    stdoutPath = $stdout
    stderrPath = $stderr
} | ConvertTo-Json | Set-Content -LiteralPath $meta -Encoding utf8
exit $code
