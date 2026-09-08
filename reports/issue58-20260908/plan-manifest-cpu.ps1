[CmdletBinding()]
param(
    [string]$ReconPath = (Join-Path $PSScriptRoot 'recon-scan.json'),
    [string]$OutputPath = (Join-Path $PSScriptRoot 'plan-manifest-cpu.json'),
    [string[]]$RunNames = @(
        '20260902T105854Z-0e2c914c-c15d-420b-b6fe-9c3',
        '20260902T104843Z-f414024c-7be1-4166-bf64-685'
    )
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repo = 'D:\agents\projects\统一环境'
$evidenceRoot = 'D:\agents\run-evidence\safe-tree-delete'
. (Join-Path $repo 'scripts\lib\CodexHostSafety.ps1')
. (Join-Path $repo 'scripts\lib\CodexSafeTreeDelete.ps1')

$recon = Get-Content -LiteralPath $ReconPath -Raw | ConvertFrom-Json
$matched = @($recon.ops | Where-Object { $RunNames -contains [string]$_.runName })
if ($matched.Count -eq 0) {
    # Fallback: take the two largest production-verified planned ops by entry count.
    $matched = @($recon.ops | Where-Object { $_.treeKind -ceq 'planned-target' } |
        Sort-Object -Property treeEntryCount -Descending | Select-Object -First 2)
}

$results = [Collections.Generic.List[object]]::new()
foreach ($op in $matched) {
    $runDirectory = Join-Path $evidenceRoot ([string]$op.runName)
    $planPath = Join-Path $runDirectory 'plan.json'
    $row = [ordered]@{
        runName = [string]$op.runName
        treeKind = [string]$op.treeKind
        planJsonBytes = [long]([IO.FileInfo]::new($planPath).Length)
        stages = [ordered]@{}
    }
    $w = [Diagnostics.Stopwatch]::StartNew()
    $planSnapshot = Read-CodexHookSafeUtf8FileSnapshot -Path $planPath `
        -Name 'issue58 plan-cpu plan' -AllowedExactPaths @($planPath)
    $w.Stop(); $row.stages['planReadHashMs'] = [long]$w.ElapsedMilliseconds

    $w = [Diagnostics.Stopwatch]::StartNew()
    Assert-CodexHookStrictJsonText -JsonText $planSnapshot.text
    $w.Stop(); $row.stages['planStrictJsonMs'] = [long]$w.ElapsedMilliseconds

    # Production pays this even when the fast-scan receipt matches
    # (scripts/lib/CodexSafeTreeDelete.ps1:4524).
    $w = [Diagnostics.Stopwatch]::StartNew()
    $plan = $planSnapshot.text | ConvertFrom-Json -Depth 128 -DateKind String -ErrorAction Stop
    $w.Stop(); $row.stages['planConvertFromJsonMs'] = [long]$w.ElapsedMilliseconds
    $row.planManifestEntryCount = [long]@($plan.treeManifest.entries).Count

    # Skipped in production when the receipt matches (CodexSafeTreeDelete.ps1:4570-4574);
    # measured here as the reference-path cost class.
    $w = [Diagnostics.Stopwatch]::StartNew()
    $converted = ConvertTo-CodexHookExpectedDirectoryTreeManifest `
        -Manifest $plan.treeManifest -Scope 'issue58 plan-cpu planned'
    $w.Stop(); $row.stages['planManifestConvertMs'] = [long]$w.ElapsedMilliseconds

    # Production pays this once per unique plan (CodexSafeTreeDelete.ps1:3172-3181 ->
    # 4421-4424): ConvertTo-Json -Depth 100 -Compress over the whole manifest + SHA-256.
    $w = [Diagnostics.Stopwatch]::StartNew()
    $manifestSha = Get-CodexSafeTreeDeleteManifestSha256 -Manifest $plan.treeManifest
    $w.Stop(); $row.stages['planManifestJsonShaMs'] = [long]$w.ElapsedMilliseconds
    $row.planManifestSha256 = [string]$manifestSha

    # Same cost class as the live-snapshot manifest serialization
    # (Get-CodexSafeTreeDeleteStatusLiveManifestSha256, CodexSafeTreeDelete.ps1:3185-3194):
    # the live snapshot carries the same entry count/shape as the plan manifest.
    $w = [Diagnostics.Stopwatch]::StartNew()
    $manifestSha2 = Get-CodexSafeTreeDeleteManifestSha256 -Manifest $plan.treeManifest
    $w.Stop(); $row.stages['manifestJsonShaRepeatMs'] = [long]$w.ElapsedMilliseconds

    $results.Add([pscustomobject]$row)
    Write-Output ("op={0} planMB={1} entries={2} stages={3}" -f $op.runName,
        [math]::Round($row.planJsonBytes / 1MB, 1), $row.planManifestEntryCount,
        (($row.stages.GetEnumerator() | ForEach-Object { "{0}={1}" -f $_.Key, $_.Value }) -join ','))
}

$out = [pscustomobject][ordered]@{
    artifactType = 'issue58.n1-plan-manifest-cpu'
    capturedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
    repoHead = (git -C $repo rev-parse HEAD).Trim()
    ops = @($results)
}
$json = $out | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText($OutputPath, $json, [Text.UTF8Encoding]::new($false))
Write-Output 'plan-cpu-done'
