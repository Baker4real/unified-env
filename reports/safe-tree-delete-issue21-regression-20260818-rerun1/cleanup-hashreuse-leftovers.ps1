Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$fixtureEntry = Join-Path $projectRoot 'tests\Invoke-CodexSafeTreeDeleteFixture.ps1'
$issue32 = Join-Path $projectRoot 'reports\safe-tree-delete-issue32-20260817'
$policyPath = Join-Path $issue32 'scale-10000\policy.json'

$jobs = @(
    [ordered]@{
        transactionPath = Join-Path $issue32 'scale-10000\evidence\20260818T153411Z-0dba05ae-b9cc-4c93-a234-738150247112\transaction.json'
        sha256 = 'b85b25be497f089c1349d02f66ed189dee62b48c8ab0f486ed365956c3c28cef'
        evidenceRoot = Join-Path $issue32 'scale-10000\evidence'
    }
    [ordered]@{
        transactionPath = Join-Path $issue32 'scale-10000\evidence\20260818T153541Z-6eed1124-fd34-4056-b1fa-43973172b4a4\transaction.json'
        sha256 = '3d47136a8b25e433d5c1b79f6d6807ce3eef9d3280cb0561e09f035c4e0af00c'
        evidenceRoot = Join-Path $issue32 'scale-10000\evidence'
    }
)

foreach ($job in $jobs) {
    $txPath = [string]$job.transactionPath
    if (-not [IO.File]::Exists($txPath)) {
        throw "transaction 不存在：$txPath"
    }
    $tx = Get-Content -Raw -LiteralPath $txPath | ConvertFrom-Json -Depth 16 -DateKind String
    $liveSha = (Get-FileHash -LiteralPath $txPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($liveSha -cne [string]$job.sha256 -and [string]$tx.status -cne 'purged') {
        throw "transaction SHA 已变 expected=$($job.sha256) actual=$liveSha status=$($tx.status)"
    }
    if ([string]$tx.status -ceq 'purged' -and -not [IO.Directory]::Exists([string]$tx.quarantinePath)) {
        Write-Output ("SKIP already purged {0}" -f $txPath)
        continue
    }
    if (-not [IO.Directory]::Exists([string]$tx.quarantinePath)) {
        throw "quarantine 不存在且 status=$($tx.status)：$($tx.quarantinePath)"
    }
    Write-Output ("PURGE {0}" -f $txPath)
    $result = & $fixtureEntry `
        -Mode Purge `
        -TransactionPath $txPath `
        -ApprovedTransactionSha256 $liveSha `
        -ConfirmPurge `
        -FixturePolicyPath $policyPath `
        -FixtureEvidenceRoot ([string]$job.evidenceRoot)
    $purged = $false
    if ($null -ne $result -and $result.PSObject.Properties['purged']) {
        $purged = [bool]$result.purged
    }
    Write-Output ('  purged={0}' -f $purged)
    if (-not $purged) {
        throw "Purge 未完成：$txPath"
    }
}

Write-Output 'CLEANUP_DONE'
exit 0
