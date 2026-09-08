[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('before', 'after', 'mid')][string]$Label,
    [string]$OutputPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repo = 'D:\agents\projects\统一环境'
$evidenceRoot = 'D:\agents\run-evidence\safe-tree-delete'
$policyPath = Join-Path $repo 'managed\safe-tree-delete\policy.json'
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $PSScriptRoot "evidence-fingerprint-$Label.json"
}
if ([IO.Path]::GetFullPath($OutputPath).StartsWith(
        $evidenceRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Fingerprint output must be outside the observed evidence root.'
}

. (Join-Path $repo 'scripts\lib\CodexHostSafety.ps1')
. (Join-Path $repo 'scripts\lib\CodexSafeTreeDelete.ps1')

function Get-TextSha256 {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
}

function Get-OperationIdFingerprint {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$OperationIds)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $sorted = [Collections.Generic.List[string]]::new()
    foreach ($operationId in $OperationIds) {
        if ($operationId -isnot [string] -or [string]::IsNullOrEmpty($operationId)) {
            throw 'Each operationId must be a nonempty JSON string.'
        }
        if (-not $seen.Add($operationId)) { throw 'Duplicate operationId in coverage.' }
        $sorted.Add($operationId)
    }
    $sorted.Sort([StringComparer]::Ordinal)
    [pscustomobject][ordered]@{
        count = $sorted.Count
        sha256 = Get-TextSha256 -Text (ConvertTo-Json -InputObject $sorted.ToArray() -Compress)
    }
}

$watch = [Diagnostics.Stopwatch]::StartNew()
$snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot `
    -Path $evidenceRoot `
    -CapabilityRoot (Split-Path -Parent $evidenceRoot) `
    -AllowedExactPaths @($evidenceRoot) `
    -Name 'issue58 N1 evidence snapshot'
$manifestSha = Get-CodexSafeTreeDeleteManifestSha256 -Manifest $snapshot
$operationIds = @($snapshot.entries | Where-Object {
    $_.relativePath -cne '.' -and -not $_.relativePath.Contains('/')
} | ForEach-Object { $_.relativePath })
$coverage = Get-OperationIdFingerprint -OperationIds $operationIds
$watch.Stop()

$policySnapshot = Get-CodexHookCapabilityFileSnapshot -Path $policyPath `
    -CapabilityRoot (Split-Path -Parent $policyPath) -AllowedExactPaths @($policyPath) `
    -Name 'issue58 N1 policy snapshot'
if (-not $policySnapshot.exists -or $policySnapshot.state -cne 'regular-file' -or
    [string]::IsNullOrWhiteSpace($policySnapshot.sha256)) {
    throw 'Policy fingerprint did not produce a regular-file SHA-256.'
}

$result = [pscustomobject][ordered]@{
    artifactType = 'issue58.n1-evidence-fingerprint'
    label = $Label
    capturedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
    elapsedMs = [long]$watch.ElapsedMilliseconds
    evidence = [pscustomobject][ordered]@{
        manifestSha256 = [string]$manifestSha
        rootIdentity = @([string[]]$snapshot.rootIdentity)
        entryCount = @($snapshot.entries).Count
        operationCount = $coverage.count
        operationIdsSha256 = $coverage.sha256
    }
    policy = [pscustomobject][ordered]@{
        path = $policySnapshot.path
        sha256 = $policySnapshot.sha256
        length = $policySnapshot.bytes.Length
        identity = @($policySnapshot.identity)
        sddl = $policySnapshot.sddl
    }
}
$json = $result | ConvertTo-Json -Depth 16
[IO.File]::WriteAllText($OutputPath, $json, [Text.UTF8Encoding]::new($false))
Write-Output ("label={0} elapsedMs={1} entryCount={2} operationCount={3} manifestSha256={4}" -f
    $Label, $watch.ElapsedMilliseconds, $result.evidence.entryCount,
    $result.evidence.operationCount, $result.evidence.manifestSha256)
Write-Output 'fingerprint-done'
