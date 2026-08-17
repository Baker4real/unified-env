# Cleanup leftover from the #20 production failure harness. reports/ allowlist only.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$wrapper = 'D:\Codex\.codex\scripts\invoke-safe-tree-delete.cmd'
$tx = 'D:\Codex\.codex\run-evidence\safe-tree-delete\20260816T021845Z-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e\transaction.json'
$quarantine = 'D:\Codex\projects\统一环境\reports\.codex-safe-delete-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e.quarantine'
$outPath = Join-Path $PSScriptRoot 'issue20-cleanup.json'

if (-not [IO.File]::Exists($tx)) {
    throw "transaction missing: $tx"
}

$sha = (Get-FileHash -LiteralPath $tx -Algorithm SHA256).Hash.ToLowerInvariant()
$raw = & $wrapper -Mode Purge -TransactionPath $tx -ApprovedTransactionSha256 $sha -ConfirmPurge -Json
$code = if (Test-Path Variable:LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
$document = $null
if (-not [string]::IsNullOrWhiteSpace(($raw -join "`n"))) {
    $document = ($raw -join "`n") | ConvertFrom-Json -Depth 16 -DateKind String
}

$result = [ordered]@{
    exitCode = $code
    approvedSha256 = $sha
    stdout = ($raw -join "`n")
    purged = $(if ($null -ne $document -and $document.PSObject.Properties.Name -contains 'purged') { [bool]$document.purged } else { $null })
    quarantineExistsAfter = [IO.Directory]::Exists($quarantine)
}
[IO.File]::WriteAllText($outPath, ($result | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
if ($code -ne 0 -or $result.purged -ne $true -or $result.quarantineExistsAfter) {
    throw "issue20 leftover purge did not complete. See $outPath"
}
$result
