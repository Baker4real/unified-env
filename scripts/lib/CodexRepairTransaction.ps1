Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'CodexHostSafety.ps1')

function Enter-CodexRepairDirectoryLease {
    param(
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [Parameter(Mandatory)][string]$Path
    )
    $root=Assert-CodexHookDPath -Value $CapabilityRoot -Name 'repair lease capability root'
    $target=Assert-CodexHookCapabilityPath -Path $Path -CapabilityRoot $root -Name 'repair directory lease'
    [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire($root,$target,$false)
}

function Enter-CodexRepairCandidateLeaseSet {
    param(
        [Parameter(Mandatory)][string]$CandidateRoot,
        [Parameter(Mandatory)][object[]]$Entries
    )
    $root=Assert-CodexHookDPath -Value $CandidateRoot -Name 'candidate lease root'
    $resources=[Collections.Generic.List[IDisposable]]::new()
    try {
        foreach($entry in @($Entries|Where-Object disposition -CEQ 'approved-candidate')){
            Assert-CodexHookExactProperties $entry @('mapName','identity','sourcePath','candidate','finalIdentity','reparse','disposition','reason') 'approved candidate entry'
            if(@($entry.finalIdentity).Count-ne2-or[string]$entry.finalIdentity[0]-cnotmatch'^[0-9a-f]{8}$'-or[string]$entry.finalIdentity[1]-cnotmatch'^[0-9a-f]{16}$'){throw 'approved candidate identity is invalid'}
            $path=Assert-CodexHookCapabilityPath -Path ([string]$entry.candidate) -CapabilityRoot $root -AllowedExactPaths @([string]$entry.candidate) -Name 'approved candidate'
            $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'approved candidate is redirected'}
            if($item.PSIsContainer){
                $guard=[CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire($root,$path,$false)
                if(@(Compare-Object @([string]$entry.finalIdentity[0],[string]$entry.finalIdentity[1]) @([string]$guard.VolumeSerialNumber,[string]$guard.FileIndex)).Count-ne0){$guard.Dispose();throw 'approved candidate directory identity changed'}
                $resources.Add($guard)
            }else{
                $guard=[CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire($root,(Split-Path -Parent $path),$false)
                $resources.Add($guard)
                $lease=$guard.AcquireReadOnlyFileLease($path)
                if(@(Compare-Object @([string]$entry.finalIdentity[0],[string]$entry.finalIdentity[1]) @([string]$lease.VolumeSerialNumber,[string]$lease.FileIndex)).Count-ne0){$lease.Dispose();throw 'approved candidate file identity changed'}
                $resources.Add($lease)
            }
        }
        [pscustomobject]@{resources=$resources.ToArray()}
    }catch{
        for($index=$resources.Count-1;$index-ge0;$index--){$resources[$index].Dispose()}
        throw
    }
}

function Exit-CodexRepairLeaseSet {
    param([AllowNull()][object]$LeaseSet)
    if($null-eq$LeaseSet){return}
    $items=@($LeaseSet.resources)
    for($index=$items.Count-1;$index-ge0;$index--){if($null-ne$items[$index]){$items[$index].Dispose()}}
}

function Protect-CodexRepairAttestation {
    param([Parameter(Mandatory)][object]$Payload)
    [byte[]]$plain=[Text.UTF8Encoding]::new($false).GetBytes(($Payload|ConvertTo-Json -Depth 64 -Compress))
    [byte[]]$entropy=[Text.UTF8Encoding]::new($false).GetBytes('codex-state-path-repair-v1/evidence-attestation')
    [byte[]]$cipher=[Security.Cryptography.ProtectedData]::Protect($plain,$entropy,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    [ordered]@{protection='dpapi-current-user-v1';trustBoundary='same-windows-user';data=[Convert]::ToBase64String($cipher)}
}

function Unprotect-CodexRepairAttestation {
    param([Parameter(Mandatory)][object]$Envelope)
    Assert-CodexHookExactProperties $Envelope @('protection','trustBoundary','data') 'state repair attestation'
    if($Envelope.protection-cne'dpapi-current-user-v1'-or$Envelope.trustBoundary-cne'same-windows-user'){throw 'state repair attestation envelope invalid'}
    try{
        [byte[]]$entropy=[Text.UTF8Encoding]::new($false).GetBytes('codex-state-path-repair-v1/evidence-attestation')
        [byte[]]$plain=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String([string]$Envelope.data),$entropy,[Security.Cryptography.DataProtectionScope]::CurrentUser)
        $text=[Text.UTF8Encoding]::new($false,$true).GetString($plain)
        Assert-CodexHookStrictJsonText -JsonText $text
        $text|ConvertFrom-Json -Depth 64 -DateKind String
    }catch{throw 'state repair attestation authentication failed'}
}

function Protect-CodexRepairApprovalPayload {
    param([Parameter(Mandatory)][object]$Payload)
    [byte[]]$plain=[Text.UTF8Encoding]::new($false).GetBytes(($Payload|ConvertTo-Json -Depth 64 -Compress))
    [byte[]]$entropy=[Text.UTF8Encoding]::new($false).GetBytes('codex-state-path-repair-v1/approval-artifact')
    [byte[]]$cipher=[Security.Cryptography.ProtectedData]::Protect($plain,$entropy,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    [ordered]@{protection='dpapi-current-user-v1';trustBoundary='same-windows-user';data=[Convert]::ToBase64String($cipher)}
}

function Unprotect-CodexRepairApprovalPayload {
    param([Parameter(Mandatory)][object]$Envelope)
    Assert-CodexHookExactProperties $Envelope @('protection','trustBoundary','data') 'state path approval attestation'
    if($Envelope.protection-cne'dpapi-current-user-v1'-or$Envelope.trustBoundary-cne'same-windows-user'){throw 'state path approval attestation envelope invalid'}
    try{
        [byte[]]$entropy=[Text.UTF8Encoding]::new($false).GetBytes('codex-state-path-repair-v1/approval-artifact')
        [byte[]]$plain=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String([string]$Envelope.data),$entropy,[Security.Cryptography.DataProtectionScope]::CurrentUser)
        $text=[Text.UTF8Encoding]::new($false,$true).GetString($plain)
        Assert-CodexHookStrictJsonText -JsonText $text
        $text|ConvertFrom-Json -Depth 64 -DateKind String
    }catch{throw 'state path approval attestation authentication failed'}
}

function Test-CodexRepairIdentityEqual {
    param([AllowNull()][object[]]$Left,[AllowNull()][object[]]$Right)
    @($Left).Count-eq2-and@($Right).Count-eq2-and
        [string]$Left[0]-ceq[string]$Right[0]-and[string]$Left[1]-ceq[string]$Right[1]
}

function ConvertFrom-CodexRepairStrictJsonSnapshot {
    param(
        [Parameter(Mandatory)][object]$Snapshot,
        [Parameter(Mandatory)][string]$Name,
        [int]$Depth = 64
    )
    if(-not$Snapshot.exists-or$Snapshot.state-cne'regular-file'){throw "$Name is unavailable"}
    try{$text=[Text.UTF8Encoding]::new($false,$true).GetString([byte[]]$Snapshot.bytes)}catch{throw "$Name is not strict UTF-8"}
    Assert-CodexHookStrictJsonText -JsonText $text
    $text|ConvertFrom-Json -Depth $Depth -DateKind String
}

function Get-CodexRepairTargetSnapshot {
    param([string]$Path,[string]$CapabilityRoot)
    $full=Assert-CodexHookCapabilityPath -Path $Path -CapabilityRoot $CapabilityRoot -AllowedExactPaths @($Path) -Name 'state repair target'
    $raw=Get-CodexHookHandleBoundFileSnapshot -Path $full -Name 'state repair target' -AllowedExactPaths @($full)
    if(-not$raw.probe.safeToRead){throw 'state repair target unavailable'}
    [pscustomobject]@{path=$full;bytes=[byte[]]$raw.bytes;sha256=Get-CodexHookBytesSha256 -Bytes ([byte[]]$raw.bytes);identity=@($raw.probe.identity)}
}

function Resolve-CodexRepairPreparedPath {
    param([string]$PreparedPath,[string]$TargetPath,[string]$CapabilityRoot)
    $fullPrepared=[IO.Path]::GetFullPath($PreparedPath)
    $targetParent=[IO.Path]::GetFullPath((Split-Path -Parent $TargetPath))
    if((Split-Path -Parent $fullPrepared)-ine$targetParent-or(Split-Path -Leaf $fullPrepared)-cnotmatch'^\.codex-hook-[0-9a-f]{32}\.tmp$'){throw 'repair intent prepared path invalid'}
    Assert-CodexHookCapabilityPath -Path $fullPrepared -CapabilityRoot $CapabilityRoot -AllowedExactPaths @($fullPrepared) -Name 'repair intent prepared file'
}

function Remove-CodexRepairPreparedFile {
    param([string]$PreparedPath,[object[]]$ExpectedIdentity,[string]$ExpectedSha256,[string]$TargetPath,[string]$CapabilityRoot,[switch]$AllowMissing)
    $fullPrepared=Resolve-CodexRepairPreparedPath -PreparedPath $PreparedPath -TargetPath $TargetPath -CapabilityRoot $CapabilityRoot
    $snapshot=Get-CodexHookCapabilityFileSnapshot -Path $fullPrepared -CapabilityRoot $CapabilityRoot -AllowedExactPaths @($fullPrepared) -Name 'repair intent prepared file probe'
    if(-not$snapshot.exists){if($AllowMissing){return $false};throw 'repair intent prepared file is missing'}
    $targetParent=[IO.Path]::GetFullPath((Split-Path -Parent $TargetPath))
    $guard=[CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire($CapabilityRoot,$targetParent,$false);$prepared=$null
    try{
        $prepared=$guard.AcquirePreparedTempFile($fullPrepared)
        if(-not(Test-CodexRepairIdentityEqual @($prepared.VolumeSerialNumber,$prepared.FileIndex) @($ExpectedIdentity))-or(Get-CodexHookBytesSha256 -Bytes $prepared.ReadAllBytesFromHandle())-cne$ExpectedSha256){throw 'repair intent prepared file drift'}
        $prepared.DeleteWithPosixSemantics()
    }finally{if($null-ne$prepared){$prepared.Dispose()};$guard.Dispose()}
    if([IO.File]::Exists($fullPrepared)){throw 'repair intent prepared file delete postcheck failed'}
    $true
}

function Set-CodexRepairJsonCas {
    param([string]$Path,[object]$Value,[string]$ExpectedSha256,[string]$CapabilityRoot)
    [byte[]]$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 64 -Compress))
    $after=Get-CodexHookBytesSha256 -Bytes $bytes
    Set-CodexHookAtomicFileBytesWithCapability -Path $Path -Bytes $bytes -ExpectedExists $true -ExpectedSha256 $ExpectedSha256 -AfterSha256 $after -CapabilityRoot $CapabilityRoot -AllowedExactPaths @($Path) -Scope 'state repair evidence update'
    $after
}

function New-CodexRepairProtectedRecord {
    param([string]$EvidencePath,[string]$FileName,[object]$Payload)
    $path=Join-Path $EvidencePath $FileName
    $expectedPayload=$Payload|ConvertTo-Json -Depth 64 -Compress
    $existing=Get-CodexHookCapabilityFileSnapshot -Path $path -CapabilityRoot $EvidencePath -AllowedExactPaths @($path) -Name 'state repair protected record existing'
    if($existing.exists){
        $envelope=ConvertFrom-CodexRepairStrictJsonSnapshot -Snapshot $existing -Name 'state repair protected record existing envelope' -Depth 16
        $actual=Unprotect-CodexRepairAttestation $envelope
        if(($actual|ConvertTo-Json -Depth 64 -Compress)-cne$expectedPayload){throw 'state repair protected record payload mismatch'}
        return [pscustomobject]@{path=$path;sha256=[string]$existing.sha256;created=$false}
    }
    $envelope=Protect-CodexRepairAttestation $Payload
    [byte[]]$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($envelope|ConvertTo-Json -Depth 16 -Compress))
    $sha=Get-CodexHookBytesSha256 -Bytes $bytes
    try{
        Set-CodexHookAtomicFileBytesWithCapability -Path $path -Bytes $bytes -ExpectedExists $false -ExpectedSha256 $null -AfterSha256 $sha -CapabilityRoot $EvidencePath -AllowedExactPaths @($path) -Scope 'state repair protected record'
        [pscustomobject]@{path=$path;sha256=$sha;created=$true}
    }catch{
        $raced=Get-CodexHookCapabilityFileSnapshot -Path $path -CapabilityRoot $EvidencePath -AllowedExactPaths @($path) -Name 'state repair protected record raced'
        if(-not$raced.exists){throw}
        $racedEnvelope=ConvertFrom-CodexRepairStrictJsonSnapshot -Snapshot $raced -Name 'state repair protected record raced envelope' -Depth 16
        $racedPayload=Unprotect-CodexRepairAttestation $racedEnvelope
        if(($racedPayload|ConvertTo-Json -Depth 64 -Compress)-cne$expectedPayload){throw 'state repair protected record race payload mismatch'}
        [pscustomobject]@{path=$path;sha256=[string]$raced.sha256;created=$false}
    }
}

function Read-CodexRepairProtectedRecord {
    param([string]$EvidencePath,[string]$FileName,[string]$Name)
    $path=Join-Path $EvidencePath $FileName
    $snapshot=Get-CodexHookCapabilityFileSnapshot -Path $path -CapabilityRoot $EvidencePath -AllowedExactPaths @($path) -Name $Name
    $envelope=ConvertFrom-CodexRepairStrictJsonSnapshot -Snapshot $snapshot -Name $Name -Depth 16
    [pscustomobject]@{snapshot=$snapshot;payload=(Unprotect-CodexRepairAttestation $envelope)}
}

function Get-CodexRepairLedgerState {
    param(
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [switch]$AllowInitialize,
        [AllowNull()][string]$PendingGenerationId,
        [AllowNull()][string]$PendingApprovalArtifactSha256
    )
    $ledgerRoot=Join-Path $EvidenceRoot '.approval-ledger'
    [void](New-CodexHookCapabilityDirectory -Path $ledgerRoot -CapabilityRoot $EvidenceRoot -Name 'state repair ledger root')
    $headPath=Join-Path $ledgerRoot 'head.json'
    $headSnapshot=Get-CodexHookCapabilityFileSnapshot -Path $headPath -CapabilityRoot $ledgerRoot -AllowedExactPaths @($headPath) -Name 'state repair ledger head'
    if(-not$headSnapshot.exists){
        $history=@()
        foreach($relative in @('approvals','.claims','.consumed-approvals','runs')){
            $root=Join-Path $EvidenceRoot $relative
            if(Test-Path -LiteralPath $root -PathType Container){$history+=@(Get-ChildItem -LiteralPath $root -Force -ErrorAction Stop)}
        }
        if($history.Count-ne0-or-not$AllowInitialize){throw 'state repair ledger head missing with approval history'}
        $payload=[ordered]@{artifactType='env-governance.codex-state-path-ledger-head';schemaVersion=1;sequence=0;latestRecordSha256=$null}
        $envelope=Protect-CodexRepairAttestation $payload
        [byte[]]$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($envelope|ConvertTo-Json -Depth 16 -Compress))
        $sha=Get-CodexHookBytesSha256 -Bytes $bytes
        Set-CodexHookAtomicFileBytesWithCapability -Path $headPath -Bytes $bytes -ExpectedExists $false -ExpectedSha256 $null -AfterSha256 $sha -CapabilityRoot $ledgerRoot -AllowedExactPaths @($headPath) -Scope 'state repair ledger initialize'
        $headSnapshot=Get-CodexHookCapabilityFileSnapshot -Path $headPath -CapabilityRoot $ledgerRoot -AllowedExactPaths @($headPath) -Name 'state repair initialized ledger head'
    }
    $headEnvelope=ConvertFrom-CodexRepairStrictJsonSnapshot -Snapshot $headSnapshot -Name 'state repair ledger head' -Depth 16
    $head=Unprotect-CodexRepairAttestation $headEnvelope
    Assert-CodexHookExactProperties $head @('artifactType','schemaVersion','sequence','latestRecordSha256') 'state repair ledger head payload'
    if($head.artifactType-cne'env-governance.codex-state-path-ledger-head'-or[int]$head.schemaVersion-ne1-or$head.sequence-isnot[long]-and$head.sequence-isnot[int]){throw 'state repair ledger head invalid'}
    $sequence=[int64]$head.sequence
    if($sequence-lt0-or($sequence-eq0-and$null-ne$head.latestRecordSha256)-or($sequence-gt0-and[string]$head.latestRecordSha256-cnotmatch'^[0-9a-f]{64}$')){throw 'state repair ledger head chain invalid'}
    $ledgerItems=@(Get-ChildItem -LiteralPath $ledgerRoot -Force -ErrorAction Stop)
    if(@($ledgerItems|Where-Object{$_.PSIsContainer-or($_.Name-cne'head.json'-and$_.Name-cnotmatch'^entry-[0-9]{16}\.json$')}).Count-ne0){throw 'state repair ledger contains an unrecognized item'}
    $records=@($ledgerItems|Where-Object{-not$_.PSIsContainer-and$_.Name-cmatch'^entry-[0-9]{16}\.json$'}|Sort-Object Name)
    $allowPending=-not[string]::IsNullOrWhiteSpace($PendingGenerationId)-and-not[string]::IsNullOrWhiteSpace($PendingApprovalArtifactSha256)
    if($records.Count-ne$sequence-and-not($allowPending-and$records.Count-eq$sequence+1)){throw 'state repair ledger record count invalid'}
    $previous=$null;$generations=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$validated=[Collections.Generic.List[object]]::new()
    for($index=0;$index-lt$records.Count;$index++){
        $expectedName='entry-{0:d16}.json' -f ($index+1)
        if($records[$index].Name-cne$expectedName){throw 'state repair ledger record sequence invalid'}
        $record=Read-CodexRepairProtectedRecord -EvidencePath $ledgerRoot -FileName $expectedName -Name 'state repair ledger record'
        Assert-CodexHookExactProperties $record.payload @('artifactType','schemaVersion','sequence','generationId','approvalArtifactSha256','previousRecordSha256','previousHeadSha256','consumedAtUtc') 'state repair ledger record payload'
        if($record.payload.artifactType-cne'env-governance.codex-state-path-ledger-record'-or[int]$record.payload.schemaVersion-ne1-or[int64]$record.payload.sequence-ne($index+1)-or$record.payload.generationId-cnotmatch'^approval-v1-[0-9a-f]{32}$'-or$record.payload.approvalArtifactSha256-cnotmatch'^[0-9a-f]{64}$'-or-not$generations.Add([string]$record.payload.generationId)){throw 'state repair ledger record invalid'}
        if(($index-eq0-and$null-ne$record.payload.previousRecordSha256)-or($index-gt0-and$record.payload.previousRecordSha256-cne$previous)){throw 'state repair ledger link invalid'}
        $previous=[string]$record.snapshot.sha256
        $validated.Add($record)
    }
    $committedLatest=if($sequence-eq0){$null}else{[string]$validated[[int]$sequence-1].snapshot.sha256}
    if(($sequence-eq0-and$null-ne$head.latestRecordSha256)-or($sequence-gt0-and$head.latestRecordSha256-cne$committedLatest)){throw 'state repair ledger head does not match chain'}
    $promotedPending=$false
    if($records.Count-eq$sequence+1){
        $pending=$validated[[int]$sequence]
        if($pending.payload.generationId-cne$PendingGenerationId-or$pending.payload.approvalArtifactSha256-cne$PendingApprovalArtifactSha256-or$pending.payload.previousHeadSha256-cne$headSnapshot.sha256){throw 'state repair pending ledger record binding invalid'}
        $nextHead=[ordered]@{artifactType='env-governance.codex-state-path-ledger-head';schemaVersion=1;sequence=$sequence+1;latestRecordSha256=[string]$pending.snapshot.sha256}
        $nextEnvelope=Protect-CodexRepairAttestation $nextHead
        [byte[]]$nextBytes=[Text.UTF8Encoding]::new($false).GetBytes(($nextEnvelope|ConvertTo-Json -Depth 16 -Compress));$nextSha=Get-CodexHookBytesSha256 -Bytes $nextBytes
        Set-CodexHookAtomicFileBytesWithCapability -Path $headPath -Bytes $nextBytes -ExpectedExists $true -ExpectedSha256 ([string]$headSnapshot.sha256) -AfterSha256 $nextSha -CapabilityRoot $ledgerRoot -AllowedExactPaths @($headPath) -Scope 'state repair pending ledger promote'
        $head=$nextHead;$headSnapshot=Get-CodexHookCapabilityFileSnapshot -Path $headPath -CapabilityRoot $ledgerRoot -AllowedExactPaths @($headPath) -Name 'state repair promoted ledger head';$committedLatest=[string]$pending.snapshot.sha256;$promotedPending=$true
    }
    [pscustomobject]@{root=$ledgerRoot;headPath=$headPath;headSnapshot=$headSnapshot;head=$head;generationIds=$generations;latestRecordSha256=$committedLatest;promotedPending=$promotedPending}
}

function Add-CodexRepairLedgerConsumption {
    param([string]$EvidenceRoot,[string]$GenerationId,[string]$ApprovalArtifactSha256,[switch]$FixtureFailFastAfterRecordCreate)
    $state=Get-CodexRepairLedgerState -EvidenceRoot $EvidenceRoot -PendingGenerationId $GenerationId -PendingApprovalArtifactSha256 $ApprovalArtifactSha256
    if($state.generationIds.Contains($GenerationId)){if($state.promotedPending){return};throw 'state repair approval already consumed'}
    $sequence=[int64]$state.head.sequence+1
    $payload=[ordered]@{artifactType='env-governance.codex-state-path-ledger-record';schemaVersion=1;sequence=$sequence;generationId=$GenerationId;approvalArtifactSha256=$ApprovalArtifactSha256;previousRecordSha256=$state.latestRecordSha256;previousHeadSha256=[string]$state.headSnapshot.sha256;consumedAtUtc=[datetimeoffset]::UtcNow.ToString('o')}
    $record=New-CodexRepairProtectedRecord -EvidencePath $state.root -FileName ('entry-{0:d16}.json' -f $sequence) -Payload $payload
    if($FixtureFailFastAfterRecordCreate){[Environment]::FailFast('fixture hard crash after ledger record create')}
    $head=[ordered]@{artifactType='env-governance.codex-state-path-ledger-head';schemaVersion=1;sequence=$sequence;latestRecordSha256=[string]$record.sha256}
    $envelope=Protect-CodexRepairAttestation $head
    [byte[]]$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($envelope|ConvertTo-Json -Depth 16 -Compress))
    $sha=Get-CodexHookBytesSha256 -Bytes $bytes
    Set-CodexHookAtomicFileBytesWithCapability -Path $state.headPath -Bytes $bytes -ExpectedExists $true -ExpectedSha256 ([string]$state.headSnapshot.sha256) -AfterSha256 $sha -CapabilityRoot $state.root -AllowedExactPaths @($state.headPath) -Scope 'state repair ledger advance'
}

function Assert-CodexRepairLedgerConsumption {
    param([string]$EvidenceRoot,[string]$GenerationId,[string]$ApprovalArtifactSha256)
    $state=Get-CodexRepairLedgerState -EvidenceRoot $EvidenceRoot
    if(-not$state.generationIds.Contains($GenerationId)){throw 'state repair approval consumption is not authenticated'}
    $recordName=$null
    foreach($file in @(Get-ChildItem -LiteralPath $state.root -Force -File -Filter 'entry-*.json')){
        $record=Read-CodexRepairProtectedRecord -EvidencePath $state.root -FileName $file.Name -Name 'state repair ledger binding record'
        if($record.payload.generationId-ceq$GenerationId){
            if($record.payload.approvalArtifactSha256-cne$ApprovalArtifactSha256){throw 'state repair ledger approval binding invalid'}
            $recordName=$file.Name
        }
    }
    if($null-eq$recordName){throw 'state repair approval ledger binding missing'}
}

function Invoke-CodexRepairStateApply {
    param(
        [string]$TargetPath,[byte[]]$BeforeBytes,[byte[]]$AfterBytes,[string]$CapabilityRoot,
        [string]$EvidenceRoot,[string]$GenerationId,[string]$ApprovalArtifactSha256,
        [object[]]$Entries,[switch]$FixtureFailCompleted,
        [AllowNull()][byte[]]$FixtureThirdPartyBytes,
        [switch]$FixtureReplaceTargetAfterApply,
        [switch]$FixtureFailFastAfterApplyRename,
        [switch]$FixtureFailFastAfterRollbackRename,
        [switch]$FixtureFailFastAfterApplyIntentCreate,
        [switch]$FixtureFailFastAfterRollbackIntentCreate,
        [switch]$FixtureFailFastAfterRestoreAttestationCreate
    )
    $beforeSha=Get-CodexHookBytesSha256 -Bytes $BeforeBytes;$afterSha=Get-CodexHookBytesSha256 -Bytes $AfterBytes
    $target=Get-CodexRepairTargetSnapshot -Path $TargetPath -CapabilityRoot $CapabilityRoot
    if($target.sha256-cne$beforeSha){throw 'state repair target changed after transform'}
    $runs=Join-Path $EvidenceRoot 'runs';[void](New-CodexHookCapabilityDirectory -Path $runs -CapabilityRoot $EvidenceRoot -Name 'state repair runs root')
    $evidence=Join-Path $runs $GenerationId;[void](New-CodexHookCapabilityDirectory -Path $evidence -CapabilityRoot $runs -Name 'state repair generation evidence' -RequireMissing)
    $backup=Join-Path $evidence 'before.bin'
    Set-CodexHookAtomicFileBytesWithCapability -Path $backup -Bytes $BeforeBytes -ExpectedExists $false -ExpectedSha256 $null -AfterSha256 $beforeSha -CapabilityRoot $evidence -AllowedExactPaths @($backup) -Scope 'state repair before backup'
    $attestationPayload=[ordered]@{artifactType='env-governance.codex-state-path-attestation';schemaVersion=1;generationId=$GenerationId;targetPath=$TargetPath;beforeBackupRelativePath='before.bin';beforeBackupSha256=$beforeSha;beforeIdentity=@($target.identity);afterSha256=$afterSha;approvalArtifactSha256=$ApprovalArtifactSha256}
    $attestation=Protect-CodexRepairAttestation $attestationPayload
    [byte[]]$attestationBytes=[Text.UTF8Encoding]::new($false).GetBytes(($attestation|ConvertTo-Json -Depth 12 -Compress))
    $attestationSha=Get-CodexHookBytesSha256 -Bytes $attestationBytes;$attestationPath=Join-Path $evidence 'attestation.json'
    Set-CodexHookAtomicFileBytesWithCapability -Path $attestationPath -Bytes $attestationBytes -ExpectedExists $false -ExpectedSha256 $null -AfterSha256 $attestationSha -CapabilityRoot $evidence -AllowedExactPaths @($attestationPath) -Scope 'state repair attestation'
    $manifest=[ordered]@{artifactType='env-governance.codex-state-path-repair-manifest';schemaVersion=1;generationId=$GenerationId;status='prepared';beforeBackupRelativePath='before.bin';beforeBackupSha256=$beforeSha;beforeIdentity=@($target.identity);afterSha256=$afterSha;afterIdentity=$null;attestationSha256=$attestationSha;applyIntentAttestationSha256=$null;completionAttestationSha256=$null;restoreIntentAttestationSha256=$null;restoredIdentity=$null;restoreAttestationSha256=$null;approvalArtifactSha256=$ApprovalArtifactSha256;entries=@($Entries);recovery=[ordered]@{required=$false;reason=$null;currentSha256=$null}}
    $manifestPath=Join-Path $evidence 'manifest.json';[byte[]]$manifestBytes=[Text.UTF8Encoding]::new($false).GetBytes(($manifest|ConvertTo-Json -Depth 64 -Compress));$manifestSha=Get-CodexHookBytesSha256 -Bytes $manifestBytes
    Set-CodexHookAtomicFileBytesWithCapability -Path $manifestPath -Bytes $manifestBytes -ExpectedExists $false -ExpectedSha256 $null -AfterSha256 $manifestSha -CapabilityRoot $evidence -AllowedExactPaths @($manifestPath) -Scope 'state repair manifest'
    $manifest.status='applying';$manifestSha=Set-CodexRepairJsonCas -Path $manifestPath -Value $manifest -ExpectedSha256 $manifestSha -CapabilityRoot $evidence
    $applyState=[pscustomobject]@{manifestSha=$manifestSha}
    try{
        if($beforeSha-cne$afterSha){
            $beforeRename={param($prepared)
                $intentPayload=[ordered]@{artifactType='env-governance.codex-state-path-apply-intent';schemaVersion=1;generationId=$GenerationId;targetPath=$TargetPath;preparedPath=[string]$prepared.path;afterSha256=$afterSha;afterIdentity=@($prepared.identity);initialAttestationSha256=$attestationSha;approvalArtifactSha256=$ApprovalArtifactSha256}
                $intent=New-CodexRepairProtectedRecord -EvidencePath $evidence -FileName 'apply-intent.json' -Payload $intentPayload
                if($FixtureFailFastAfterApplyIntentCreate){[Environment]::FailFast('fixture hard crash after apply intent create')}
                $manifest.applyIntentAttestationSha256=[string]$intent.sha256
                $manifest.afterIdentity=@($prepared.identity)
                $manifest.status='applying-intent'
                $applyState.manifestSha=Set-CodexRepairJsonCas -Path $manifestPath -Value $manifest -ExpectedSha256 ([string]$applyState.manifestSha) -CapabilityRoot $evidence
            }
            Set-CodexHookAtomicFileBytesWithCapability -Path $TargetPath -Bytes $AfterBytes -ExpectedExists $true -ExpectedSha256 $beforeSha -ExpectedIdentity @($target.identity) -AfterSha256 $afterSha -CapabilityRoot $CapabilityRoot -AllowedExactPaths @($TargetPath) -Scope 'state repair apply' -BeforeRename $beforeRename -PreservePreparedTempOnRenameFailure
            $manifestSha=[string]$applyState.manifestSha
            if($FixtureFailFastAfterApplyRename){[Environment]::FailFast('fixture hard crash after state apply rename')}
        }
        $confirmed=Get-CodexRepairTargetSnapshot -Path $TargetPath -CapabilityRoot $CapabilityRoot;if($confirmed.sha256-cne$afterSha){throw 'state repair postwrite hash mismatch'}
        $afterIdentity=@($confirmed.identity)
        if(-not(Test-CodexRepairIdentityEqual @($manifest.afterIdentity) $afterIdentity)){throw 'state repair postwrite identity mismatch'}
        if($FixtureReplaceTargetAfterApply){
            $replacement=Join-Path (Split-Path -Parent $TargetPath) ".codex-state-replacement-$([guid]::NewGuid().ToString('N')).tmp"
            try{[IO.File]::WriteAllBytes($replacement,$AfterBytes);[IO.File]::Move($replacement,$TargetPath,$true)}finally{if([IO.File]::Exists($replacement)){[IO.File]::Delete($replacement)}}
            throw 'fixture same-bytes target identity drift'
        }
        $completionPayload=[ordered]@{artifactType='env-governance.codex-state-path-completion-attestation';schemaVersion=1;generationId=$GenerationId;targetPath=$TargetPath;afterSha256=$afterSha;afterIdentity=$afterIdentity;initialAttestationSha256=$attestationSha;approvalArtifactSha256=$ApprovalArtifactSha256}
        $completionRecord=New-CodexRepairProtectedRecord -EvidencePath $evidence -FileName 'completion-attestation.json' -Payload $completionPayload
        $manifest.completionAttestationSha256=[string]$completionRecord.sha256
        if($null-ne$FixtureThirdPartyBytes){
            $thirdSha=Get-CodexHookBytesSha256 -Bytes $FixtureThirdPartyBytes
            Set-CodexHookAtomicFileBytesWithCapability -Path $TargetPath -Bytes $FixtureThirdPartyBytes -ExpectedExists $true -ExpectedSha256 $afterSha -AfterSha256 $thirdSha -CapabilityRoot $CapabilityRoot -AllowedExactPaths @($TargetPath) -Scope 'state repair fixture third-party publish'
            throw 'fixture third-party state drift'
        }
        if($FixtureFailCompleted){throw 'fixture completed evidence failure'}
        $manifest.status='completed';$manifestSha=Set-CodexRepairJsonCas -Path $manifestPath -Value $manifest -ExpectedSha256 $manifestSha -CapabilityRoot $evidence
        [pscustomobject]@{changed=$beforeSha-cne$afterSha;evidencePath=$evidence;afterSha256=$afterSha;manifestSha256=$manifestSha}
    }catch{
        $failure=$_
        $manifestSha=[string]$applyState.manifestSha
        try{
            $current=Get-CodexRepairTargetSnapshot -Path $TargetPath -CapabilityRoot $CapabilityRoot
            if($current.sha256-ceq$afterSha-and$beforeSha-cne$afterSha-and(Test-CodexRepairIdentityEqual @($current.identity) @($manifest.afterIdentity))){
                $rollbackState=[pscustomobject]@{manifestSha=$manifestSha}
                $beforeRollbackRename={param($prepared)
                    $restoreIntentPayload=[ordered]@{artifactType='env-governance.codex-state-path-restore-intent';schemaVersion=1;generationId=$GenerationId;targetPath=$TargetPath;preparedPath=[string]$prepared.path;beforeSha256=$beforeSha;restoredIdentity=@($prepared.identity);afterSha256=$afterSha;afterIdentity=@($manifest.afterIdentity);initialAttestationSha256=$attestationSha}
                    $intent=New-CodexRepairProtectedRecord -EvidencePath $evidence -FileName 'restore-intent.json' -Payload $restoreIntentPayload
                    if($FixtureFailFastAfterRollbackIntentCreate){[Environment]::FailFast('fixture hard crash after automatic rollback intent create')}
                    $manifest.status='restoring-intent';$manifest.restoredIdentity=@($prepared.identity);$manifest.restoreIntentAttestationSha256=[string]$intent.sha256
                    $rollbackState.manifestSha=Set-CodexRepairJsonCas -Path $manifestPath -Value $manifest -ExpectedSha256 ([string]$rollbackState.manifestSha) -CapabilityRoot $evidence
                }
                Set-CodexHookAtomicFileBytesWithCapability -Path $TargetPath -Bytes $BeforeBytes -ExpectedExists $true -ExpectedSha256 $afterSha -ExpectedIdentity @($manifest.afterIdentity) -AfterSha256 $beforeSha -CapabilityRoot $CapabilityRoot -AllowedExactPaths @($TargetPath) -Scope 'state repair reverse CAS' -BeforeRename $beforeRollbackRename -PreservePreparedTempOnRenameFailure
                $manifestSha=[string]$rollbackState.manifestSha
                if($FixtureFailFastAfterRollbackRename){[Environment]::FailFast('fixture hard crash after automatic rollback rename')}
                $rolledBack=Get-CodexRepairTargetSnapshot -Path $TargetPath -CapabilityRoot $CapabilityRoot;$manifest.restoredIdentity=@($rolledBack.identity);$restorePayload=[ordered]@{artifactType='env-governance.codex-state-path-restore-attestation';schemaVersion=1;generationId=$GenerationId;targetPath=$TargetPath;beforeSha256=$beforeSha;restoredIdentity=@($rolledBack.identity);afterSha256=$afterSha;afterIdentity=@($manifest.afterIdentity)};$restoreRecord=New-CodexRepairProtectedRecord -EvidencePath $evidence -FileName 'restore-attestation.json' -Payload $restorePayload;if($FixtureFailFastAfterRestoreAttestationCreate){[Environment]::FailFast('fixture hard crash after automatic rollback attestation create')};$manifest.restoreAttestationSha256=[string]$restoreRecord.sha256;$manifest.status='rolled-back'
            }
            elseif($current.sha256-ceq$beforeSha-and(Test-CodexRepairIdentityEqual @($current.identity) @($target.identity))){
                $applyIntentPath=Join-Path $evidence 'apply-intent.json'
                if(Test-Path -LiteralPath $applyIntentPath -PathType Leaf){
                    $applyIntent=Read-CodexRepairProtectedRecord -EvidencePath $evidence -FileName 'apply-intent.json' -Name 'failed apply intent'
                    Assert-CodexHookExactProperties $applyIntent.payload @('artifactType','schemaVersion','generationId','targetPath','preparedPath','afterSha256','afterIdentity','initialAttestationSha256','approvalArtifactSha256') 'failed apply intent payload'
                    if($applyIntent.payload.artifactType-cne'env-governance.codex-state-path-apply-intent'-or[int]$applyIntent.payload.schemaVersion-ne1-or$applyIntent.payload.generationId-cne$GenerationId-or$applyIntent.payload.targetPath-cne$TargetPath-or$applyIntent.payload.afterSha256-cne$afterSha-or$applyIntent.payload.initialAttestationSha256-cne$attestationSha-or$applyIntent.payload.approvalArtifactSha256-cne$ApprovalArtifactSha256){throw 'failed apply intent payload binding invalid'}
                    [void](Remove-CodexRepairPreparedFile -PreparedPath ([string]$applyIntent.payload.preparedPath) -ExpectedIdentity @($applyIntent.payload.afterIdentity) -ExpectedSha256 $afterSha -TargetPath $TargetPath -CapabilityRoot $CapabilityRoot -AllowMissing)
                }
                $manifest.restoredIdentity=@($current.identity);$restorePayload=[ordered]@{artifactType='env-governance.codex-state-path-restore-attestation';schemaVersion=1;generationId=$GenerationId;targetPath=$TargetPath;beforeSha256=$beforeSha;restoredIdentity=@($current.identity);afterSha256=$afterSha;afterIdentity=@($manifest.afterIdentity)};$restoreRecord=New-CodexRepairProtectedRecord -EvidencePath $evidence -FileName 'restore-attestation.json' -Payload $restorePayload;$manifest.restoreAttestationSha256=[string]$restoreRecord.sha256;$manifest.status='rolled-back'
            }
            elseif($current.sha256-ceq$afterSha-or$current.sha256-ceq$beforeSha){$manifest.status='rollback-blocked';$manifest.recovery.required=$true;$manifest.recovery.reason='third-party-state-identity-drift';$manifest.recovery.currentSha256=$current.sha256}
            else{$manifest.status='rollback-blocked';$manifest.recovery.required=$true;$manifest.recovery.reason='third-party-state-drift';$manifest.recovery.currentSha256=$current.sha256}
        }catch{if($manifest.status-cne'restoring-intent'){$manifest.status='rollback-blocked';$manifest.recovery.required=$true;$manifest.recovery.reason='rollback-failed'}}
        try{[void](Set-CodexRepairJsonCas -Path $manifestPath -Value $manifest -ExpectedSha256 $manifestSha -CapabilityRoot $evidence)}catch{}
        throw $failure
    }
}

function Invoke-CodexRepairStateRestore {
    param([string]$TargetPath,[string]$CapabilityRoot,[string]$EvidenceRoot,[string]$EvidencePath,[switch]$FixtureFailFastAfterRestoreRename,[switch]$FixtureFailFastAfterRestoreIntentCreate,[switch]$FixtureFailFastAfterRestoreAttestationCreate,[switch]$FixtureThrowOnRestoreRename,[switch]$FixtureFailFastAfterApplyTempCleanup)
    $runs=Join-Path $EvidenceRoot 'runs';$evidence=Assert-CodexHookCapabilityPath -Path $EvidencePath -CapabilityRoot $runs -Name 'state repair restore evidence'
    if((Split-Path -Parent $evidence)-ine[IO.Path]::GetFullPath($runs)){throw 'restore evidence must be a direct generation directory'}
    $manifestPath=Join-Path $evidence 'manifest.json';$attestationPath=Join-Path $evidence 'attestation.json';$backupPath=Join-Path $evidence 'before.bin'
    $manifestSnapshot=Get-CodexHookCapabilityFileSnapshot -Path $manifestPath -CapabilityRoot $evidence -AllowedExactPaths @($manifestPath) -Name 'restore manifest'
    $attestationSnapshot=Get-CodexHookCapabilityFileSnapshot -Path $attestationPath -CapabilityRoot $evidence -AllowedExactPaths @($attestationPath) -Name 'restore attestation'
    $backupSnapshot=Get-CodexHookCapabilityFileSnapshot -Path $backupPath -CapabilityRoot $evidence -AllowedExactPaths @($backupPath) -Name 'restore backup'
    if(-not$manifestSnapshot.exists-or-not$attestationSnapshot.exists-or-not$backupSnapshot.exists){throw 'restore evidence closure missing'}
    $manifest=ConvertFrom-CodexRepairStrictJsonSnapshot -Snapshot $manifestSnapshot -Name 'restore manifest'
    $envelope=ConvertFrom-CodexRepairStrictJsonSnapshot -Snapshot $attestationSnapshot -Name 'restore attestation' -Depth 12
    $attested=Unprotect-CodexRepairAttestation $envelope
    Assert-CodexHookExactProperties $manifest @('artifactType','schemaVersion','generationId','status','beforeBackupRelativePath','beforeBackupSha256','beforeIdentity','afterSha256','afterIdentity','attestationSha256','applyIntentAttestationSha256','completionAttestationSha256','restoreIntentAttestationSha256','restoredIdentity','restoreAttestationSha256','approvalArtifactSha256','entries','recovery') 'state repair restore manifest'
    Assert-CodexHookExactProperties $manifest.recovery @('required','reason','currentSha256') 'state repair recovery'
    Assert-CodexHookExactProperties $attested @('artifactType','schemaVersion','generationId','targetPath','beforeBackupRelativePath','beforeBackupSha256','beforeIdentity','afterSha256','approvalArtifactSha256') 'state repair attestation payload'
    if($manifest.artifactType-cne'env-governance.codex-state-path-repair-manifest'-or[int]$manifest.schemaVersion-ne1-or$manifest.generationId-cne(Split-Path -Leaf $evidence)-or$manifest.status-cnotin@('applying','applying-intent','completed','restoring-intent','restored','rolled-back','rollback-blocked')){throw 'restore manifest identity/status invalid'}
    if($manifest.status-ceq'rollback-blocked'){throw 'restore rejected rollback-blocked evidence'}
    $approvalPath=Join-Path (Join-Path $EvidenceRoot 'approvals') "$($manifest.generationId).json"
    $approvalSnapshot=Get-CodexHookCapabilityFileSnapshot -Path $approvalPath -CapabilityRoot (Join-Path $EvidenceRoot 'approvals') -AllowedExactPaths @($approvalPath) -Name 'restore approval artifact'
    $approval=ConvertFrom-CodexRepairStrictJsonSnapshot -Snapshot $approvalSnapshot -Name 'restore approval artifact'
    Assert-CodexHookExactProperties $approval @('artifactType','schemaVersion','generationId','coreInventoryGeneration','nonce','generatedAtUtc','expiresAtUtc','stateSha256','mappingSha256','approvedMappingHash','candidateRoot','approvedMap','entries','state','attestation') 'restore approval artifact'
    $approvalPayload=Get-StatePathApprovalPayload -Artifact $approval
    $attestedApproval=Unprotect-CodexRepairApprovalPayload -Envelope $approval.attestation
    if(($approvalPayload|ConvertTo-Json -Depth 64 -Compress)-cne($attestedApproval|ConvertTo-Json -Depth 64 -Compress)-or$approval.artifactType-cne'env-governance.codex-state-path-approval'-or[int]$approval.schemaVersion-ne1-or$approval.generationId-cne$manifest.generationId-or$approval.state-cne'fresh'){throw 'restore approval binding invalid'}
    Assert-CodexRepairLedgerConsumption -EvidenceRoot $EvidenceRoot -GenerationId ([string]$manifest.generationId) -ApprovalArtifactSha256 ([string]$approvalSnapshot.sha256)
    if($manifest.attestationSha256-cne$attestationSnapshot.sha256-or$manifest.approvalArtifactSha256-cne$approvalSnapshot.sha256-or$attested.artifactType-cne'env-governance.codex-state-path-attestation'-or[int]$attested.schemaVersion-ne1-or$attested.generationId-cne$manifest.generationId-or$attested.targetPath-cne$TargetPath-or$attested.beforeBackupRelativePath-cne'before.bin'-or$attested.beforeBackupSha256-cne$backupSnapshot.sha256-or$attested.afterSha256-cne$manifest.afterSha256-or$attested.approvalArtifactSha256-cne$approvalSnapshot.sha256-or-not(Test-CodexRepairIdentityEqual @($attested.beforeIdentity) @($manifest.beforeIdentity))){throw 'restore evidence attestation binding invalid'}
    $manifestSha=[string]$manifestSnapshot.sha256
    $applyIntentPath=Join-Path $evidence 'apply-intent.json'
    $applyIntentSnapshot=Get-CodexHookCapabilityFileSnapshot -Path $applyIntentPath -CapabilityRoot $evidence -AllowedExactPaths @($applyIntentPath) -Name 'restore apply intent probe'
    $applyIntent=$null
    if($applyIntentSnapshot.exists){
        $applyIntent=Read-CodexRepairProtectedRecord -EvidencePath $evidence -FileName 'apply-intent.json' -Name 'restore apply intent'
        Assert-CodexHookExactProperties $applyIntent.payload @('artifactType','schemaVersion','generationId','targetPath','preparedPath','afterSha256','afterIdentity','initialAttestationSha256','approvalArtifactSha256') 'restore apply intent payload'
        if($applyIntent.payload.artifactType-cne'env-governance.codex-state-path-apply-intent'-or[int]$applyIntent.payload.schemaVersion-ne1-or$applyIntent.payload.generationId-cne$manifest.generationId-or$applyIntent.payload.targetPath-cne$TargetPath-or$applyIntent.payload.afterSha256-cne$manifest.afterSha256-or$applyIntent.payload.initialAttestationSha256-cne$manifest.attestationSha256-or$applyIntent.payload.approvalArtifactSha256-cne$manifest.approvalArtifactSha256){throw 'restore apply intent payload binding invalid'}
        [void](Resolve-CodexRepairPreparedPath -PreparedPath ([string]$applyIntent.payload.preparedPath) -TargetPath $TargetPath -CapabilityRoot $CapabilityRoot)
        if($manifest.status-cne'applying'-and($applyIntent.snapshot.sha256-cne[string]$manifest.applyIntentAttestationSha256-or-not(Test-CodexRepairIdentityEqual @($applyIntent.payload.afterIdentity) @($manifest.afterIdentity)))){throw 'restore apply intent binding invalid'}
    }elseif($manifest.status-cne'applying'){throw 'restore apply intent is missing'}
    if($null-ne$manifest.completionAttestationSha256){
        $completion=Read-CodexRepairProtectedRecord -EvidencePath $evidence -FileName 'completion-attestation.json' -Name 'restore completion attestation'
        Assert-CodexHookExactProperties $completion.payload @('artifactType','schemaVersion','generationId','targetPath','afterSha256','afterIdentity','initialAttestationSha256','approvalArtifactSha256') 'restore completion attestation payload'
        if($completion.snapshot.sha256-cne[string]$manifest.completionAttestationSha256-or$completion.payload.artifactType-cne'env-governance.codex-state-path-completion-attestation'-or[int]$completion.payload.schemaVersion-ne1-or$completion.payload.generationId-cne$manifest.generationId-or$completion.payload.targetPath-cne$TargetPath-or$completion.payload.afterSha256-cne$manifest.afterSha256-or-not(Test-CodexRepairIdentityEqual @($completion.payload.afterIdentity) @($manifest.afterIdentity))-or$completion.payload.initialAttestationSha256-cne$manifest.attestationSha256-or$completion.payload.approvalArtifactSha256-cne$manifest.approvalArtifactSha256){throw 'restore completion attestation binding invalid'}
    }
    $current=Get-CodexRepairTargetSnapshot -Path $TargetPath -CapabilityRoot $CapabilityRoot
    if($manifest.status-ceq'applying'-and$current.sha256-ceq$backupSnapshot.sha256-and(Test-CodexRepairIdentityEqual @($current.identity) @($manifest.beforeIdentity))){
        if($null-ne$applyIntent){$deleted=Remove-CodexRepairPreparedFile -PreparedPath ([string]$applyIntent.payload.preparedPath) -ExpectedIdentity @($applyIntent.payload.afterIdentity) -ExpectedSha256 ([string]$manifest.afterSha256) -TargetPath $TargetPath -CapabilityRoot $CapabilityRoot -AllowMissing;if($deleted-and$FixtureFailFastAfterApplyTempCleanup){[Environment]::FailFast('fixture hard crash after apply prepared temp cleanup')}}
        $manifest.status='rolled-back';$manifest.restoredIdentity=@($current.identity)
        $restorePayload=[ordered]@{artifactType='env-governance.codex-state-path-restore-attestation';schemaVersion=1;generationId=[string]$manifest.generationId;targetPath=$TargetPath;beforeSha256=[string]$backupSnapshot.sha256;restoredIdentity=@($current.identity);afterSha256=[string]$manifest.afterSha256;afterIdentity=$null}
        $restoreRecord=New-CodexRepairProtectedRecord -EvidencePath $evidence -FileName 'restore-attestation.json' -Payload $restorePayload
        $manifest.restoreAttestationSha256=[string]$restoreRecord.sha256
        [void](Set-CodexRepairJsonCas -Path $manifestPath -Value $manifest -ExpectedSha256 $manifestSha -CapabilityRoot $evidence)
        return [pscustomobject]@{restored=$false;noOp=$true;evidencePath=$evidence}
    }
    if($manifest.status-ceq'applying'){
        if($null-eq$applyIntent-or$current.sha256-cne[string]$manifest.afterSha256-or-not(Test-CodexRepairIdentityEqual @($current.identity) @($applyIntent.payload.afterIdentity))){throw 'restore applying target or prepared intent drift'}
        $manifest.applyIntentAttestationSha256=[string]$applyIntent.snapshot.sha256;$manifest.afterIdentity=@($applyIntent.payload.afterIdentity);$manifest.status='applying-intent'
        $manifestSha=Set-CodexRepairJsonCas -Path $manifestPath -Value $manifest -ExpectedSha256 $manifestSha -CapabilityRoot $evidence
    }
    if($manifest.status-ceq'applying-intent'-and$current.sha256-ceq$backupSnapshot.sha256-and(Test-CodexRepairIdentityEqual @($current.identity) @($manifest.beforeIdentity))){
        if($null-ne$applyIntent){$deleted=Remove-CodexRepairPreparedFile -PreparedPath ([string]$applyIntent.payload.preparedPath) -ExpectedIdentity @($applyIntent.payload.afterIdentity) -ExpectedSha256 ([string]$manifest.afterSha256) -TargetPath $TargetPath -CapabilityRoot $CapabilityRoot -AllowMissing;if($deleted-and$FixtureFailFastAfterApplyTempCleanup){[Environment]::FailFast('fixture hard crash after apply prepared temp cleanup')}}
        $manifest.status='rolled-back';$manifest.restoredIdentity=@($current.identity)
        $restorePayload=[ordered]@{artifactType='env-governance.codex-state-path-restore-attestation';schemaVersion=1;generationId=[string]$manifest.generationId;targetPath=$TargetPath;beforeSha256=[string]$backupSnapshot.sha256;restoredIdentity=@($current.identity);afterSha256=[string]$manifest.afterSha256;afterIdentity=@($manifest.afterIdentity)}
        $restoreRecord=New-CodexRepairProtectedRecord -EvidencePath $evidence -FileName 'restore-attestation.json' -Payload $restorePayload
        $manifest.restoreAttestationSha256=[string]$restoreRecord.sha256
        [void](Set-CodexRepairJsonCas -Path $manifestPath -Value $manifest -ExpectedSha256 $manifestSha -CapabilityRoot $evidence)
        return [pscustomobject]@{restored=$false;noOp=$true;evidencePath=$evidence}
    }
    $restoreIntentPath=Join-Path $evidence 'restore-intent.json'
    $restoreIntentSnapshot=Get-CodexHookCapabilityFileSnapshot -Path $restoreIntentPath -CapabilityRoot $evidence -AllowedExactPaths @($restoreIntentPath) -Name 'restore intent probe'
    $restoreIntent=$null
    $restoreIntentNeedsPromotion=$false
    $preparedPath=$null
    if($restoreIntentSnapshot.exists){
        $restoreIntent=Read-CodexRepairProtectedRecord -EvidencePath $evidence -FileName 'restore-intent.json' -Name 'restore intent'
        Assert-CodexHookExactProperties $restoreIntent.payload @('artifactType','schemaVersion','generationId','targetPath','preparedPath','beforeSha256','restoredIdentity','afterSha256','afterIdentity','initialAttestationSha256') 'restore intent payload'
        if($restoreIntent.payload.artifactType-cne'env-governance.codex-state-path-restore-intent'-or[int]$restoreIntent.payload.schemaVersion-ne1-or$restoreIntent.payload.generationId-cne$manifest.generationId-or$restoreIntent.payload.targetPath-cne$TargetPath-or$restoreIntent.payload.beforeSha256-cne$backupSnapshot.sha256-or$restoreIntent.payload.afterSha256-cne$manifest.afterSha256-or-not(Test-CodexRepairIdentityEqual @($restoreIntent.payload.afterIdentity) @($manifest.afterIdentity))-or$restoreIntent.payload.initialAttestationSha256-cne$manifest.attestationSha256){throw 'restore intent payload binding invalid'}
        $preparedPath=Resolve-CodexRepairPreparedPath -PreparedPath ([string]$restoreIntent.payload.preparedPath) -TargetPath $TargetPath -CapabilityRoot $CapabilityRoot
        if($manifest.status-cin@('completed','applying-intent')){
            $restoreIntentNeedsPromotion=$true
        }elseif($manifest.status-cin@('restoring-intent','restored','rolled-back')-and$restoreIntent.snapshot.sha256-cne[string]$manifest.restoreIntentAttestationSha256){throw 'restore intent manifest binding invalid'}
    }elseif($manifest.status-ceq'restoring-intent'){throw 'restore intent is missing'}
    if($null-ne$restoreIntent-and($restoreIntentNeedsPromotion-or$manifest.status-ceq'restoring-intent')){
        if($current.sha256-ceq$backupSnapshot.sha256-and(Test-CodexRepairIdentityEqual @($current.identity) @($restoreIntent.payload.restoredIdentity))){
            if($restoreIntentNeedsPromotion){
                $manifest.status='restoring-intent';$manifest.restoredIdentity=@($restoreIntent.payload.restoredIdentity);$manifest.restoreIntentAttestationSha256=[string]$restoreIntent.snapshot.sha256
                $manifestSha=Set-CodexRepairJsonCas -Path $manifestPath -Value $manifest -ExpectedSha256 $manifestSha -CapabilityRoot $evidence
            }
            $restorePayload=[ordered]@{artifactType='env-governance.codex-state-path-restore-attestation';schemaVersion=1;generationId=[string]$manifest.generationId;targetPath=$TargetPath;beforeSha256=[string]$backupSnapshot.sha256;restoredIdentity=@($current.identity);afterSha256=[string]$manifest.afterSha256;afterIdentity=@($manifest.afterIdentity)}
            $restoreRecord=New-CodexRepairProtectedRecord -EvidencePath $evidence -FileName 'restore-attestation.json' -Payload $restorePayload
            if($FixtureFailFastAfterRestoreAttestationCreate){[Environment]::FailFast('fixture hard crash after restore attestation create')}
            $manifest.status='restored';$manifest.restoredIdentity=@($current.identity);$manifest.restoreAttestationSha256=[string]$restoreRecord.sha256
            [void](Set-CodexRepairJsonCas -Path $manifestPath -Value $manifest -ExpectedSha256 $manifestSha -CapabilityRoot $evidence)
            return [pscustomobject]@{restored=$true;noOp=$false;evidencePath=$evidence}
        }
        if($current.sha256-cne[string]$manifest.afterSha256-or-not(Test-CodexRepairIdentityEqual @($current.identity) @($manifest.afterIdentity))){throw 'restore intent target drift'}
        $targetParent=[IO.Path]::GetFullPath((Split-Path -Parent $TargetPath))
        $guard=[CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire($CapabilityRoot,$targetParent,$false);$prepared=$null;$targetLease=$null
        try{
            $prepared=$guard.AcquirePreparedTempFile($preparedPath)
            if(-not(Test-CodexRepairIdentityEqual @($prepared.VolumeSerialNumber,$prepared.FileIndex) @($restoreIntent.payload.restoredIdentity))-or(Get-CodexHookBytesSha256 -Bytes $prepared.ReadAllBytesFromHandle())-cne$backupSnapshot.sha256){throw 'restore intent prepared file drift'}
            $targetLease=$guard.AcquireTargetFileLease($TargetPath)
            if(-not(Test-CodexRepairIdentityEqual @($targetLease.VolumeSerialNumber,$targetLease.FileIndex) @($manifest.afterIdentity))-or(Get-CodexHookBytesSha256 -Bytes $targetLease.ReadAllBytesFromHandle())-cne$manifest.afterSha256){throw 'restore intent target lease drift'}
            if($restoreIntentNeedsPromotion){
                $manifest.status='restoring-intent';$manifest.restoredIdentity=@($restoreIntent.payload.restoredIdentity);$manifest.restoreIntentAttestationSha256=[string]$restoreIntent.snapshot.sha256
                $manifestSha=Set-CodexRepairJsonCas -Path $manifestPath -Value $manifest -ExpectedSha256 $manifestSha -CapabilityRoot $evidence
            }
            $prepared.RenameTo($TargetPath,$true)
        }finally{if($null-ne$targetLease){$targetLease.Dispose()};if($null-ne$prepared){$prepared.Dispose()};$guard.Dispose()}
        $current=Get-CodexRepairTargetSnapshot -Path $TargetPath -CapabilityRoot $CapabilityRoot
        if($current.sha256-cne$backupSnapshot.sha256-or-not(Test-CodexRepairIdentityEqual @($current.identity) @($restoreIntent.payload.restoredIdentity))){throw 'restore intent resumed rename postcheck failed'}
        $restorePayload=[ordered]@{artifactType='env-governance.codex-state-path-restore-attestation';schemaVersion=1;generationId=[string]$manifest.generationId;targetPath=$TargetPath;beforeSha256=[string]$backupSnapshot.sha256;restoredIdentity=@($current.identity);afterSha256=[string]$manifest.afterSha256;afterIdentity=@($manifest.afterIdentity)}
        $restoreRecord=New-CodexRepairProtectedRecord -EvidencePath $evidence -FileName 'restore-attestation.json' -Payload $restorePayload
        if($FixtureFailFastAfterRestoreAttestationCreate){[Environment]::FailFast('fixture hard crash after restore attestation create')}
        $manifest.status='restored';$manifest.restoredIdentity=@($current.identity);$manifest.restoreAttestationSha256=[string]$restoreRecord.sha256
        [void](Set-CodexRepairJsonCas -Path $manifestPath -Value $manifest -ExpectedSha256 $manifestSha -CapabilityRoot $evidence)
        return [pscustomobject]@{restored=$true;noOp=$false;evidencePath=$evidence}
    }
    if($manifest.status-cin@('restored','rolled-back')){
        $restoreRecord=Read-CodexRepairProtectedRecord -EvidencePath $evidence -FileName 'restore-attestation.json' -Name 'restore completion record'
        Assert-CodexHookExactProperties $restoreRecord.payload @('artifactType','schemaVersion','generationId','targetPath','beforeSha256','restoredIdentity','afterSha256','afterIdentity') 'restore completion record payload'
        if($restoreRecord.snapshot.sha256-cne[string]$manifest.restoreAttestationSha256-or$restoreRecord.payload.artifactType-cne'env-governance.codex-state-path-restore-attestation'-or[int]$restoreRecord.payload.schemaVersion-ne1-or$restoreRecord.payload.generationId-cne$manifest.generationId-or$restoreRecord.payload.targetPath-cne$TargetPath-or$restoreRecord.payload.beforeSha256-cne$backupSnapshot.sha256-or-not(Test-CodexRepairIdentityEqual @($restoreRecord.payload.restoredIdentity) @($manifest.restoredIdentity))-or-not(Test-CodexRepairIdentityEqual @($current.identity) @($manifest.restoredIdentity))-or$current.sha256-cne$backupSnapshot.sha256){throw 'restore completed target identity drift'}
        return [pscustomobject]@{restored=$false;noOp=$true;evidencePath=$evidence}
    }
    if($current.sha256-ceq$backupSnapshot.sha256){throw 'restore target has third-party identity drift'}
    if($current.sha256-cne[string]$manifest.afterSha256){throw 'restore target has third-party drift'}
    if(-not(Test-CodexRepairIdentityEqual @($current.identity) @($manifest.afterIdentity))){throw 'restore target has third-party identity drift'}
    $restoreState=[pscustomobject]@{manifestSha=$manifestSha}
    $beforeRestoreRename={param($prepared)
        $restoreIntentPayload=[ordered]@{artifactType='env-governance.codex-state-path-restore-intent';schemaVersion=1;generationId=[string]$manifest.generationId;targetPath=$TargetPath;preparedPath=[string]$prepared.path;beforeSha256=[string]$backupSnapshot.sha256;restoredIdentity=@($prepared.identity);afterSha256=[string]$manifest.afterSha256;afterIdentity=@($manifest.afterIdentity);initialAttestationSha256=[string]$manifest.attestationSha256}
        $intent=New-CodexRepairProtectedRecord -EvidencePath $evidence -FileName 'restore-intent.json' -Payload $restoreIntentPayload
        if($FixtureFailFastAfterRestoreIntentCreate){[Environment]::FailFast('fixture hard crash after restore intent create')}
        $manifest.status='restoring-intent';$manifest.restoredIdentity=@($prepared.identity);$manifest.restoreIntentAttestationSha256=[string]$intent.sha256
        $restoreState.manifestSha=Set-CodexRepairJsonCas -Path $manifestPath -Value $manifest -ExpectedSha256 ([string]$restoreState.manifestSha) -CapabilityRoot $evidence
    }
    $renameAction=if($FixtureThrowOnRestoreRename){{param($prepared,$path,$replace);throw 'fixture ordinary restore rename failure'}}else{$null}
    Set-CodexHookAtomicFileBytesWithCapability -Path $TargetPath -Bytes ([byte[]]$backupSnapshot.bytes) -ExpectedExists $true -ExpectedSha256 ([string]$manifest.afterSha256) -ExpectedIdentity @($manifest.afterIdentity) -AfterSha256 ([string]$backupSnapshot.sha256) -CapabilityRoot $CapabilityRoot -AllowedExactPaths @($TargetPath) -Scope 'state repair restore' -BeforeRename $beforeRestoreRename -PreservePreparedTempOnRenameFailure -RenameAction $renameAction
    if($FixtureFailFastAfterRestoreRename){[Environment]::FailFast('fixture hard crash after state restore rename')}
    $restored=Get-CodexRepairTargetSnapshot -Path $TargetPath -CapabilityRoot $CapabilityRoot
    $restorePayload=[ordered]@{artifactType='env-governance.codex-state-path-restore-attestation';schemaVersion=1;generationId=[string]$manifest.generationId;targetPath=$TargetPath;beforeSha256=[string]$backupSnapshot.sha256;restoredIdentity=@($restored.identity);afterSha256=[string]$manifest.afterSha256;afterIdentity=@($manifest.afterIdentity)}
    $restoreRecord=New-CodexRepairProtectedRecord -EvidencePath $evidence -FileName 'restore-attestation.json' -Payload $restorePayload
    if($FixtureFailFastAfterRestoreAttestationCreate){[Environment]::FailFast('fixture hard crash after restore attestation create')}
    $manifest.status='restored';$manifest.restoredIdentity=@($restored.identity);$manifest.restoreAttestationSha256=[string]$restoreRecord.sha256
    [void](Set-CodexRepairJsonCas -Path $manifestPath -Value $manifest -ExpectedSha256 ([string]$restoreState.manifestSha) -CapabilityRoot $evidence)
    [pscustomobject]@{restored=$true;noOp=$false;evidencePath=$evidence}
}
