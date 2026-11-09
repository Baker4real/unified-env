#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = 'D:/agents/run-evidence/host-diagnostics-fixtures/sensitive-log-' + [guid]::NewGuid().ToString('N')
[void][IO.Directory]::CreateDirectory($root)
$entry = Join-Path $PSScriptRoot 'Protect-SensitiveLog.ps1'
$secrets = @('fixture-user-secret','fixture-token-secret','krxfixture999999','aB3dE5fG7hJ9kL1mN3pQ5rS7','fixture-diff-secret')
$hashLine = '2026/10/28 21:00:06 sha256 ' + ('ab' * 32)
$lines = @(
    '[2026-10-28 21:00:00] net new job from xmr-eu.kryptex.network:7029 diff 400015 height 3793995',
    '2026/10/28 21:00:01 Starting process: miner --user fixture-user-secret --pass x',
    '2026/10/28 21:00:02 token=fixture-token-secret',
    '2026/10/28 21:00:03 user krxfixture999999 connected',
    "2026/10/28 21:00:04 id $($secrets[3])",
    '2026/10/28 21:00:05 diff 400015 token=fixture-diff-secret',
    $hashLine,
    '[2026-10-28 21:00:07] miner speed 10s/60s/15m 1900.0 1800.0 n/a H/s'
)
$log = Join-Path $root 'input.txt'
[IO.File]::WriteAllLines($log, $lines, [Text.UTF8Encoding]::new($false))
$before = (Get-FileHash -LiteralPath $log -Algorithm SHA256).Hash
$results = @()
$output = & $entry -LiteralPath $log -Tail 100 -MaxLines 20 -MaxBytes 4096
$code = $LASTEXITCODE
$json = $output | ConvertFrom-Json
$serialized = $output -join "`n"
$secretFree = $true
foreach ($secret in $secrets) { if ($serialized.Contains($secret)) { $secretFree = $false } }
$results += [pscustomobject]@{ case = 'sensitive-lines-fail-closed'; passed = ($code -eq 1 -and $json.droppedRows -eq 5 -and $secretFree -and $json.returnedRows -eq 3) }
# sha256/diff/height 只豁免 24 位长串那条规则；同一行里的已知凭据形态照样剔除。
$results += [pscustomobject]@{ case = 'exemption-limited-to-long-token-rule'; passed = (-not $serialized.Contains('fixture-diff-secret') -and @($json.lines) -contains $hashLine) }
$results += [pscustomobject]@{ case = 'source-unchanged'; passed = ((Get-FileHash -LiteralPath $log -Algorithm SHA256).Hash -eq $before) }
$limited = & $entry -LiteralPath $log -Tail 100 -MaxLines 1 -MaxBytes 256 | ConvertFrom-Json
$results += [pscustomobject]@{ case = 'bounded-projection'; passed = ($limited.returnedRows -le 1 -and $limited.utf8Bytes -le 256 -and $limited.truncated) }
[pscustomobject]@{ status = $(if (@($results | Where-Object { -not $_.passed }).Count -eq 0) { 'passed' } else { 'failed' }); cases = $results.Count; results = $results; evidenceDirectory = $root } | ConvertTo-Json -Depth 5
if (@($results | Where-Object { -not $_.passed }).Count -gt 0) { exit 1 }
exit 0
