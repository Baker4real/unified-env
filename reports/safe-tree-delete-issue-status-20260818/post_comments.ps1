$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$numbers = @(
    18, 21, 22, 24, 26,
    32, 33, 35, 36, 37, 39, 40, 41, 42, 43,
    45, 48, 49, 52, 53
)
$results = [System.Collections.Generic.List[object]]::new()
foreach ($n in $numbers) {
    $body = Join-Path $dir "comment-$n.md"
    if (-not (Test-Path -LiteralPath $body)) {
        $results.Add([pscustomobject]@{ number = $n; ok = $false; url = $null; error = "missing $body"; exitCode = -1 })
        Write-Output "FAILED #$n : missing $body"
        break
    }
    $out = & gh issue comment $n --body-file $body 2>&1
    $code = $LASTEXITCODE
    $text = ($out | Out-String).Trim()
    $results.Add([pscustomobject]@{
        number = $n
        ok = ($code -eq 0)
        url = $(if ($code -eq 0) { $text } else { $null })
        error = $(if ($code -ne 0) { $text } else { $null })
        exitCode = $code
    })
    if ($code -ne 0) {
        Write-Output "FAILED #$n : $text"
        break
    }
    Write-Output $text
}
$jsonPath = Join-Path $dir 'post-results.json'
$results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $jsonPath -Encoding utf8
$failed = @($results | Where-Object { -not $_.ok })
Write-Output "POSTED=$($results.Count) FAILED=$($failed.Count)"
if ($failed.Count -gt 0) { exit 1 }
exit 0
