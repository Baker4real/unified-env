#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LiteralPath,
    [ValidateRange(1,10000)][int]$Tail = 200,
    [ValidateRange(1,1000)][int]$MaxLines = 40,
    [ValidateRange(256,65536)][int]$MaxBytes = 6000,
    [datetime]$Since
)
$ErrorActionPreference = 'Stop'
function Protect-SensitiveLogLine([string]$Line) {
    $blocked = @(
        '(?i)Starting process', '(?i)--user\b', '(?i)--pass\b', '(?i)wallet', '(?i)email',
        '(?i)authorization', '(?i)cookie', '(?i)token', '(?i)password',
        '(?i)\bkrx[a-z0-9_-]{6,}\b', '(?i)eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.'
    )
    foreach ($pattern in $blocked) {
        if ($Line -match $pattern) { return $null }
    }
    # 疑似未知高熵秘密：sha256/diff/height 行常带长哈希，只有这一条规则对它们放行。
    if ($Line -match '(?i)\b(?:[A-Za-z0-9_-]{24,})\b' -and $Line -notmatch '(?i)sha256|diff|height') { return $null }
    $Line
}
$utf8 = [Text.UTF8Encoding]::new($false)
$lines = @()
$dropped = 0
$truncated = $false
$bytes = 0
$source = Get-Content -LiteralPath $LiteralPath -Tail $Tail -ErrorAction Stop
foreach ($line in $source) {
    if ($Since) {
        $match = [regex]::Match($line, '(\d{4})[-/](\d{2})[-/](\d{2})')
        if ($match.Success) {
            $day = [datetime]::ParseExact($match.Value.Replace('/','-'), 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
            if ($day -lt $Since.Date) { continue }
        }
    }
    $safe = Protect-SensitiveLogLine $line
    if ($null -eq $safe) { $dropped++; continue }
    $lineBytes = $utf8.GetByteCount($safe) + 1
    if ($lines.Count -ge $MaxLines -or $bytes + $lineBytes -gt $MaxBytes) { $truncated = $true; continue }
    $lines += $safe
    $bytes += $lineBytes
}
$status = if ($dropped -gt 0) { 'read-with-omissions' } elseif ($truncated) { 'truncated' } else { 'passed' }
[pscustomobject]@{ status = $status; lines = $lines; returnedRows = $lines.Count; droppedRows = $dropped; truncated = $truncated; utf8Bytes = $bytes } | ConvertTo-Json -Depth 4
if ($dropped -gt 0) { exit 1 }
