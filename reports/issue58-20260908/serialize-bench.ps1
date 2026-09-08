[CmdletBinding()]
param(
    [string]$StdoutPath = (Join-Path $PSScriptRoot 'cold-run-stdout.json'),
    [string]$OutputPath = (Join-Path $PSScriptRoot 'serialize-bench.json')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Approximates the entry-point serialization (Invoke-CodexSafeTreeDelete.ps1:132-133,
# ConvertTo-Json -Depth 12 -Compress) using the captured real Status payload.
$readWatch = [Diagnostics.Stopwatch]::StartNew()
$text = [IO.File]::ReadAllText($StdoutPath)
$readWatch.Stop()
$parseWatch = [Diagnostics.Stopwatch]::StartNew()
$parsed = ConvertFrom-Json -InputObject $text -Depth 128 -DateKind String
$parseWatch.Stop()
$serWatch = [Diagnostics.Stopwatch]::StartNew()
$reserialized = $parsed | ConvertTo-Json -Depth 12 -Compress
$serWatch.Stop()

$out = [pscustomobject][ordered]@{
    artifactType = 'issue58.n1-serialize-bench'
    capturedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
    inputBytes = [Text.Encoding]::UTF8.GetByteCount($text)
    readMs = [long]$readWatch.ElapsedMilliseconds
    parseMs = [long]$parseWatch.ElapsedMilliseconds
    serializeMs = [long]$serWatch.ElapsedMilliseconds
    outputBytes = [Text.Encoding]::UTF8.GetByteCount($reserialized)
    operationCount = @($parsed.operations).Count
    note = 'Re-serialization of the parsed cold-run payload approximates production serialization of live PSObjects; same cmdlet/depth/payload size.'
}
$json = $out | ConvertTo-Json -Depth 6
[IO.File]::WriteAllText($OutputPath, $json, [Text.UTF8Encoding]::new($false))
Write-Output ("parseMs={0} serializeMs={1} ops={2}" -f $out.parseMs, $out.serializeMs, $out.operationCount)
Write-Output 'serialize-bench-done'
