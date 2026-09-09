param([Parameter(Mandatory)][string]$Payload, [string[]]$PayloadArguments=@())
$ErrorActionPreference = 'Stop'
$self = [Diagnostics.Process]::GetCurrentProcess()
$receipt = @{
    tokenSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($env:ISSUE58_OWNER_TOKEN))).ToLowerInvariant()
    processId = $PID
    parentProcessId = [int]$env:ISSUE58_PARENT_PID
    startTimeUtc = $self.StartTime.ToUniversalTime().ToString('o')
    executable = [Environment]::ProcessPath
    executableSha256 = (Get-FileHash -LiteralPath ([Environment]::ProcessPath)).Hash.ToLowerInvariant()
    version = $PSVersionTable.PSVersion.ToString()
}
$receiptPath = Join-Path $env:ISSUE58_RECEIPT_ROOT "$PID.json"
$pendingPath = "$receiptPath.pending"
$stream = [IO.File]::Open($pendingPath, [IO.FileMode]::CreateNew)
try { $stream.Write([Text.Encoding]::UTF8.GetBytes(($receipt | ConvertTo-Json))) } finally { $stream.Dispose() }
[IO.File]::Move($pendingPath,$receiptPath)
$read = [Console]::In.ReadLineAsync()
if (-not $read.Wait(10000) -or $read.Result -cne 'GO') { exit 97 }
& $Payload @PayloadArguments
if (Test-Path Variable:LASTEXITCODE) { exit $LASTEXITCODE }
