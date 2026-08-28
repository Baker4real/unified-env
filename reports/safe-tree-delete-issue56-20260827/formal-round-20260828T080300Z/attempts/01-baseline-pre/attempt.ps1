Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = 'D:\agents\projects\统一环境'
. (Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1')
$scaleRoot = 'D:\agents\projects\统一环境\reports\safe-tree-delete-issue56-20260827\formal-round-20260828T080300Z\attempts\01-baseline-pre'
$policyPath = Join-Path $scaleRoot 'policy.json'
$evidenceRoot = Join-Path $scaleRoot 'evidence'
[void][IO.Directory]::CreateDirectory($evidenceRoot)
[IO.File]::WriteAllText($policyPath, (@{
    artifactType = 'env-governance.codex-safe-tree-delete-policy'
    schemaVersion = 3
    entries = @(@{
        id = 'issue56-formal'
        capabilityRoot = $scaleRoot
        minimumDescendantDepth = 1
        rootDeletionPurpose = 'none'
        deniedExactPaths = @($evidenceRoot)
    })
} | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
$target = Join-Path $scaleRoot 'attempt-tree'
$registry = Get-CodexHostSafetyNativeLoaderRegistryState
$attestation = [pscustomobject][ordered]@{
    kind = 'baseline'
    resolvedAlgorithm = (Get-CodexHostSafetyNativeResolvedWalkerAlgorithm)
    loadedVariant = $(if ($null -ne $registry) { [string]$registry.loadedVariant } else { $null })
    psVersion = [string]$PSVersionTable.PSVersion
    processorCount = [int][Environment]::ProcessorCount
    attemptUtc = [datetimeoffset]::UtcNow.ToString('o')
}
function Remove-Tree {
    param([string]$TreePath)
    if (-not [IO.Directory]::Exists($TreePath)) { return }
    $parent = Split-Path -Parent $TreePath
    $snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot -Path $TreePath -CapabilityRoot $parent -AllowedExactPaths @($TreePath) -Name 'issue56 formal cleanup'
    Remove-CodexHookCapabilityDirectoryTree -Path $TreePath -CapabilityRoot $parent -AllowedExactPaths @($TreePath) -ExpectedRootIdentity @($snapshot.rootIdentity) -ExpectedTreeManifest $snapshot -Scope 'issue56 formal cleanup'
}
function New-ScaleTree {
    param([string]$TreePath, [int]$FileCountValue, [int]$BytesPerFileValue)
    if ([IO.Directory]::Exists($TreePath)) { Remove-Tree -TreePath $TreePath }
    $directoryCount = [Math]::Max(1, [int][Math]::Ceiling($FileCountValue / 100.0))
    $payload = [byte[]]::new($BytesPerFileValue)
    for ($index = 0; $index -lt $payload.Length; $index++) { $payload[$index] = [byte](($index + 17) % 251) }
    $written = 0
    for ($directoryIndex = 0; $directoryIndex -lt $directoryCount -and $written -lt $FileCountValue; $directoryIndex++) {
        $directory = Join-Path $TreePath ('d{0:D3}' -f $directoryIndex)
        [void][IO.Directory]::CreateDirectory($directory)
        $batch = [Math]::Min(100, $FileCountValue - $written)
        for ($fileIndex = 0; $fileIndex -lt $batch; $fileIndex++) {
            [IO.File]::WriteAllBytes((Join-Path $directory ('f{0:D2}.bin' -f $fileIndex)), $payload)
            $written += 1
        }
    }
    if ($written -ne $FileCountValue) { throw "tree 写出 $written" }
}
[void](New-ScaleTree -TreePath $target -FileCountValue 10000 -BytesPerFileValue 4096)
$plan = New-CodexSafeTreeDeletePlan -TargetPath $target -CapabilityRoot $scaleRoot -PolicyPath $policyPath -EvidenceRoot $evidenceRoot -DisablePlanCSharpWalkerForTest
$attemptWalkerKind = $(if ([string]$script:CodexSafeTreeDeleteLastPlanSegments.walker -ceq 'csharp') { 'csharp-plan-snapshot' } else { 'powershell-three-pass' })
$apply = Invoke-CodexSafeTreeDeleteQuarantine -PlanPath ([string]$plan.planPath) -ApprovedPlanSha256 ([string]$plan.planSha256) -PolicyPath $policyPath -EvidenceRoot $evidenceRoot -DisableApplyHashReuseForTest
$purge = Invoke-CodexSafeTreeDeletePurge -TransactionPath ([string]$apply.transactionPath) -ApprovedTransactionSha256 ([string]$apply.transactionSha256) -PolicyPath $policyPath -EvidenceRoot $evidenceRoot -DisablePurgeHashReuseForTest
if (-not [bool]$purge.purged) { throw 'baseline Purge 未成功' }
$attestation | Add-Member -NotePropertyName result -NotePropertyValue ([pscustomobject][ordered]@{
    walkerKind = $attemptWalkerKind
    planElapsedMs = [long]$plan.metrics.elapsedMs
    applyElapsedMs = [long]$apply.metrics.elapsedMs
    purgeElapsedMs = [long]$purge.metrics.elapsedMs
    endToEndElapsedMs = [long]$plan.metrics.elapsedMs + [long]$apply.metrics.elapsedMs + [long]$purge.metrics.elapsedMs
    baselineMode = $true
})
$attestation | ConvertTo-Json -Depth 8