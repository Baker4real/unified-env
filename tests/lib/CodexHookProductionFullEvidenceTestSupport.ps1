Set-StrictMode -Version Latest

function New-TestCodexHookProductionFullAttestedLineage {
    param(
        [Parameter(Mandatory)][object]$Profile,
        [AllowNull()][AllowEmptyCollection()][object[]]$PredecessorIndexes
    )
    $nodes=[Collections.Generic.List[object]]::new()
    foreach($index in 0..($PredecessorIndexes.Count-1)){
        $generationId=[guid]::NewGuid().ToString()
        $paths=Get-CodexHookProductionFullLifecyclePaths -Profile $Profile -GenerationId $generationId
        $nodes.Add([pscustomobject][ordered]@{
            artifactType='env-governance.codex-hook-production-full-active';schemaVersion=1;profileId=[string]$Profile.profileId
            generationId=$generationId;evidenceDirectory=[string]$paths.evidenceDirectory;state='applied'
            previousGenerationId=$null;previousEvidenceDirectory=$null
        })
    }
    foreach($index in 0..($PredecessorIndexes.Count-1)){
        $predecessorIndex=$PredecessorIndexes[$index]
        if($null -eq $predecessorIndex){continue}
        $node=$nodes[$index];$predecessor=$nodes[[int]$predecessorIndex]
        $node.previousGenerationId=[string]$predecessor.generationId
        $node.previousEvidenceDirectory=[string]$predecessor.evidenceDirectory
    }
    foreach($index in 0..($PredecessorIndexes.Count-1)){
        $predecessorIndex=$PredecessorIndexes[$index]
        if($null -eq $predecessorIndex){continue}
        $node=$nodes[$index];$predecessor=$nodes[[int]$predecessorIndex]
        $paths=Get-CodexHookProductionFullLifecyclePaths -Profile $Profile -GenerationId ([string]$node.generationId)
        [void][IO.Directory]::CreateDirectory([string]$paths.backupsRoot)
        [void][IO.Directory]::CreateDirectory([string]$paths.claimsRoot)
        [byte[]]$previousBytes=[Text.UTF8Encoding]::new($false).GetBytes(($predecessor|ConvertTo-Json -Depth 16))
        $previousPath=Join-Path ([string]$paths.evidenceDirectory) 'backups\previous-active.json'
        [IO.File]::WriteAllBytes($previousPath,$previousBytes)
        $previousSha=Get-CodexHookBytesSha256 $previousBytes
        $restore=[pscustomobject][ordered]@{previousActiveBackupRelativePath='backups\previous-active.json';previousActiveBackupSha256=$previousSha}
        [byte[]]$restoreBytes=[Text.UTF8Encoding]::new($false).GetBytes(($restore|ConvertTo-Json -Depth 16))
        [IO.File]::WriteAllBytes([string]$paths.restoreManifestPath,$restoreBytes)
        $restoreSha=Get-CodexHookBytesSha256 $restoreBytes
        $attestationPayload=[pscustomobject][ordered]@{generationId=[string]$node.generationId;restoreManifestSha256=$restoreSha;previousActiveBackupSha256=$previousSha}
        $attestation=Protect-CodexHookProductionFullAttestation $attestationPayload
        [byte[]]$attestationBytes=[Text.UTF8Encoding]::new($false).GetBytes(($attestation|ConvertTo-Json -Depth 16))
        [IO.File]::WriteAllBytes([string]$paths.attestationPath,$attestationBytes)
        $claim=[pscustomobject][ordered]@{restoreManifestSha256=$restoreSha;attestationSha256=Get-CodexHookBytesSha256 $attestationBytes}
        [IO.File]::WriteAllText([string]$paths.claimPath,($claim|ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($false))
    }
    return $nodes[0]
}
