[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('I1','I2','I3','I4','I5','I6','I7','I8','I9','I10','I11','I12','I13','I14','I15','I16','I17','I18','I19','I20','I21','I22','I23','I24','I25')][string]$Case)
$ErrorActionPreference='Stop'; Set-StrictMode -Version Latest
$ProjectRoot='D:\Codex\projects\统一环境'
$Entry=Join-Path $ProjectRoot 'scripts\Get-CodexStatePathInventory.ps1'
$FixtureParent=Join-Path $ProjectRoot 'reports\codex-state-path-repair-test'
$ManagedRoot=Join-Path $ProjectRoot 'managed\codex-hooks'
. (Join-Path $ProjectRoot 'scripts\lib\CodexHookPolicy.ps1')
. (Join-Path $ProjectRoot 'scripts\lib\CodexRepairTransaction.ps1')
$CaseDescriptions=[ordered]@{
    I1='managed tree remains read-only during inventory';I2='scaled path classification';I3='approval replay rejection';I4='candidate replacement rejection'
    I5='evidence restore and rollback states';I6='evidence ancestor replacement rejection';I7='strict approval closure';I8='candidate identity leases'
    I9='target identity CAS';I10='mode contract and single JSON failures';I11='legacy consumed-ledger replay';I12='read-only file lease primitive'
    I13='converged repair no-op';I14='apply rename hard-crash recovery';I15='restore rename hard-crash recovery';I16='authenticated fixed replay ledger'
    I17='strict DPAPI attestation decoding';I18='automatic rollback rename hard-crash recovery'
    I19='orphan apply intent promotion';I20='orphan manual restore intent promotion';I21='orphan automatic rollback intent promotion'
    I22='orphan terminal restore attestation promotion';I23='authenticated pending ledger promotion';I24='ordinary restore rename failure resumes prepared temp';I25='prepared cleanup hard-crash idempotence'
}

function Get-TreeFingerprint([string]$Root) {
    @(Get-ChildItem -LiteralPath $Root -Recurse -Force|Sort-Object FullName|ForEach-Object{
        [ordered]@{path=[IO.Path]::GetRelativePath($Root,$_.FullName);kind=if($_.PSIsContainer){'d'}else{'f'};length=if($_.PSIsContainer){$null}else{$_.Length};sha256=if($_.PSIsContainer){$null}else{(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}}
    })|ConvertTo-Json -Depth 6 -Compress
}
function New-Fixture([switch]$Scale,[switch]$FileCandidate,[switch]$NoOp) {
    $root=Join-Path $FixtureParent ([guid]::NewGuid().ToString('N'));$fixtureHome=Join-Path $root 'codex-home';New-Item -ItemType Directory -Path $fixtureHome -Force|Out-Null
    [IO.File]::WriteAllText((Join-Path $root '.codex-state-path-repair-fixture'),'codex-state-path-repair-test-v1',[Text.UTF8Encoding]::new($false))
    $config='approval_policy = "never"'+[Environment]::NewLine+'sandbox_mode = "danger-full-access"'+[Environment]::NewLine
    [IO.File]::WriteAllText((Join-Path $fixtureHome 'config.toml'),$config,[Text.UTF8Encoding]::new($false))
    $policy='{"approvalPolicy":"never","sandboxPolicy":{"type":"dangerFullAccess"}}';foreach($n in @('policy.json','state-policy.json')){[IO.File]::WriteAllText((Join-Path $fixtureHome $n),$policy,[Text.UTF8Encoding]::new($false))}
    $candidate=Join-Path $root 'candidate-root';$map=[ordered]@{}
    if($Scale){
        New-Item -ItemType Directory -Path $candidate|Out-Null
        0..170|ForEach-Object{$leaf='safe-{0:d3}' -f $_;New-Item -ItemType Directory -Path (Join-Path $candidate $leaf)|Out-Null;$map[$leaf]="C:\Users\WINDOWS\Documents\Codex\$leaf"}
        0..4|ForEach-Object{$leaf='missing-{0:d3}' -f $_;$map[$leaf]="C:\Users\WINDOWS\Documents\Codex\$leaf"}
        New-Item -ItemType Directory -Path (Join-Path $root 'junction-target')|Out-Null
        $mk=Start-Process cmd.exe -ArgumentList @('/d','/c','mklink','/J',(Join-Path $candidate 'junction'),(Join-Path $root 'junction-target')) -NoNewWindow -Wait -PassThru;if($mk.ExitCode-ne 0){throw 'junction setup failed'}
        $map.junction='C:\Users\WINDOWS\Documents\Codex\junction';New-Item -ItemType Directory -Path (Join-Path $candidate 'ambiguous')|Out-Null
        $map.ambiguousA='C:\Users\WINDOWS\Documents\Codex\ambiguous';$map.ambiguousB='C:\Users\WINDOWS\Documents\Codex\ambiguous'
    }elseif($FileCandidate){New-Item -ItemType Directory -Path $candidate -Force|Out-Null;[IO.File]::WriteAllBytes((Join-Path $candidate 'safe-file'),[byte[]](1,2,3,4));$map.safeFile='C:\Users\WINDOWS\Documents\Codex\safe-file'}
    else{New-Item -ItemType Directory -Path (Join-Path $candidate 'safe') -Force|Out-Null;$map.safe='C:\Users\WINDOWS\Documents\Codex\safe'}
    if($NoOp){$map=[ordered]@{safe=(Join-Path $candidate 'safe')}}
    $state=[ordered]@{'thread-workspace-root-hints'=$map;untouched=[ordered]@{sentinel='preserve'}};$statePath=Join-Path $fixtureHome '.codex-global-state.json'
    [IO.File]::WriteAllText($statePath,($state|ConvertTo-Json -Depth 10 -Compress),[Text.UTF8Encoding]::new($false))
    [pscustomobject]@{Root=$root;Home=$fixtureHome;StatePath=$statePath;CandidateRoot=$candidate}
}
function Invoke-Entry([string[]]$Arguments,[hashtable]$Environment=@{}) {
    $saved=@{};try{foreach($k in $Environment.Keys){$saved[$k]=[Environment]::GetEnvironmentVariable($k,'Process');[Environment]::SetEnvironmentVariable($k,[string]$Environment[$k],'Process')}
        $text=& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File $Entry @Arguments 2>&1;[pscustomobject]@{ExitCode=$LASTEXITCODE;Text=($text-join[Environment]::NewLine)}
    }finally{foreach($k in $Environment.Keys){[Environment]::SetEnvironmentVariable($k,$saved[$k],'Process')}}
}
function Read-Result($Run){if($Run.ExitCode-ne 0){throw "command failed: $($Run.Text)"};$Run.Text|ConvertFrom-Json -Depth 64}
function Assert-SingleJsonFailure($Run,[string]$Label) {
    if($Run.ExitCode-eq 0){throw "$Label must fail"}
    $lines=@($Run.Text -split '\r?\n'|Where-Object{-not[string]::IsNullOrWhiteSpace($_)})
    if($lines.Count-ne1){throw "$Label emitted $($lines.Count) lines instead of one JSON object: $($Run.Text)"}
    try{$value=$lines[0]|ConvertFrom-Json -Depth 16}catch{throw "$Label did not emit JSON: $($Run.Text)"}
    $names=@($value.PSObject.Properties.Name)
    if(@(Compare-Object @('schemaVersion','mode','ok','error') $names).Count-ne0-or$value.ok-ne$false-or$value.error.code-cne'state-path-maintenance-failed'){throw "$Label emitted an invalid failure envelope: $($Run.Text)"}
    if($Run.Text-cmatch'[A-Z]:\\'){throw "$Label leaked an absolute path: $($Run.Text)"}
}

$f=$null
try{
switch($Case){
'I1'{$f=New-Fixture;$before=Get-TreeFingerprint $ManagedRoot;$r=Invoke-Entry @('-Mode','Inventory','-FixtureRoot',$f.Root,'-Json');if($r.ExitCode-ne 0){throw $r.Text};$after=Get-TreeFingerprint $ManagedRoot;if($before-cne$after){throw 'I1 RED managed source tree changed'};$s=Get-Content -Raw $Entry;if($s-cnotmatch '-I\s+-B\s+-c'){throw 'I1 RED Python invocation lacks -B'};if($s-cnotmatch 'sys\.dont_write_bytecode\s*=\s*True'){throw 'I1 RED adapter lacks dont_write_bytecode'}}
'I2'{$f=New-Fixture -Scale;$i=Read-Result (Invoke-Entry @('-Mode','Inventory','-FixtureRoot',$f.Root,'-Json'));if([string]$i.candidateRoot-cne[string]$f.CandidateRoot){throw 'I2 RED fixture candidate root not bound'};if($i.summary.safeCount-ne171-or$i.summary.missingCount-ne5-or$i.summary.reparseCount-ne1-or$i.summary.ambiguousCount-ne2){throw "I2 RED bad classification counts: $($i.summary|ConvertTo-Json -Compress)"}}
'I3'{$f=New-Fixture;$i=Read-Result (Invoke-Entry @('-Mode','Inventory','-FixtureRoot',$f.Root,'-Json'));if(-not(Test-Path -LiteralPath ([string]$i.approvalArtifactPath)-PathType Leaf)){throw 'I3 RED approval artifact missing'};$a=Get-Content -Raw $i.approvalArtifactPath|ConvertFrom-Json -Depth 64;if([string]$a.nonce-cnotmatch'^[0-9a-f]{32}$'-or$a.state-cne'fresh'){throw 'I3 RED nonce/fresh state missing'};$args=@('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration',$i.generationId,'-ApprovedMappingHash',$i.approvedMappingHash,'-Json');$first=Invoke-Entry $args;if($first.ExitCode-ne0){throw $first.Text};$orig=[ordered]@{'thread-workspace-root-hints'=[ordered]@{safe='C:\Users\WINDOWS\Documents\Codex\safe'};untouched=[ordered]@{sentinel='preserve'}};[IO.File]::WriteAllText($f.StatePath,($orig|ConvertTo-Json -Depth 8 -Compress),[Text.UTF8Encoding]::new($false));$bytes=[IO.File]::ReadAllBytes($f.StatePath);$replay=Invoke-Entry $args;if($replay.ExitCode-eq0){throw 'I3 RED consumed approval replayed'};if(@(Compare-Object $bytes ([IO.File]::ReadAllBytes($f.StatePath))).Count-ne0){throw 'I3 RED replay changed state'}}
'I4'{$f=New-Fixture -Scale;$i=Read-Result (Invoke-Entry @('-Mode','Inventory','-FixtureRoot',$f.Root,'-Json'));$bytes=[IO.File]::ReadAllBytes($f.StatePath);$r=Invoke-Entry @('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration',$i.generationId,'-ApprovedMappingHash',$i.approvedMappingHash,'-Json') @{CODEX_STATE_PATH_REPAIR_FIXTURE_REPLACE_CANDIDATE='safe-000'};if($r.ExitCode-eq0){throw 'I4 RED candidate replacement accepted'};if(@(Compare-Object $bytes ([IO.File]::ReadAllBytes($f.StatePath))).Count-ne0){throw 'I4 RED candidate drift changed state'}}
'I5'{
    $f=New-Fixture
    $before=[IO.File]::ReadAllBytes($f.StatePath)
    $i=Read-Result (Invoke-Entry @('-Mode','Inventory','-FixtureRoot',$f.Root,'-Json'))
    $repair=Read-Result (Invoke-Entry @('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration',$i.generationId,'-ApprovedMappingHash',$i.approvedMappingHash,'-Json'))
    $m=Get-Content -Raw (Join-Path $repair.evidencePath 'manifest.json')|ConvertFrom-Json -Depth 64
    foreach($n in @('beforeBackupRelativePath','beforeBackupSha256','beforeIdentity','afterSha256','attestationSha256','recovery')){if($n-notin@($m.PSObject.Properties.Name)){throw "I5 RED evidence missing $n"}}
    if(@($m.beforeIdentity).Count-ne2-or[string]$m.beforeIdentity[0]-cnotmatch'^[0-9a-f]{8}$'-or[string]$m.beforeIdentity[1]-cnotmatch'^[0-9a-f]{16}$'){throw 'I5 RED evidence lacks handle-bound file identity'}
    $identityPath=Join-Path $f.Root 'identity-same-bytes.bin'
    $replacementPath=Join-Path $f.Root 'identity-replacement.bin'
    [IO.File]::WriteAllBytes($identityPath,[byte[]](1,2,3,4))
    $firstIdentity=@((Get-CodexHookHandleBoundFileSnapshot -Path $identityPath -Name 'identity canary before' -AllowedExactPaths @($identityPath)).probe.identity)
    [IO.File]::WriteAllBytes($replacementPath,[byte[]](1,2,3,4))
    [IO.File]::Move($replacementPath,$identityPath,$true)
    $secondIdentity=@((Get-CodexHookHandleBoundFileSnapshot -Path $identityPath -Name 'identity canary after' -AllowedExactPaths @($identityPath)).probe.identity)
    if(@(Compare-Object $firstIdentity $secondIdentity).Count-eq0){throw 'I5 RED same-path same-bytes replacement retained file identity'}
    $restore=Invoke-Entry @('-Mode','Restore','-FixtureRoot',$f.Root,'-EvidencePath',$repair.evidencePath,'-Json')
    if($restore.ExitCode-ne0){throw 'I5 RED Restore unavailable'}
    if(@(Compare-Object $before ([IO.File]::ReadAllBytes($f.StatePath))).Count-ne0){throw 'I5 RED Restore bytes differ'}
    $again=Invoke-Entry @('-Mode','Restore','-FixtureRoot',$f.Root,'-EvidencePath',$repair.evidencePath,'-Json')
    if($again.ExitCode-ne0){throw 'I5 RED Restore not reentrant'}

    $finalizationFixture=New-Fixture
    try {
        $finalizationBefore=[IO.File]::ReadAllBytes($finalizationFixture.StatePath)
        $finalizationInventory=Read-Result (Invoke-Entry @('-Mode','Inventory','-FixtureRoot',$finalizationFixture.Root,'-Json'))
        $failed=Invoke-Entry @('-Mode','Repair','-FixtureRoot',$finalizationFixture.Root,'-InventoryGeneration',$finalizationInventory.generationId,'-ApprovedMappingHash',$finalizationInventory.approvedMappingHash,'-Json') @{CODEX_STATE_PATH_REPAIR_FIXTURE_FAIL_COMPLETED='1'}
        if($failed.ExitCode-eq0){throw 'I5 RED finalization failure was accepted'}
        if(@(Compare-Object $finalizationBefore ([IO.File]::ReadAllBytes($finalizationFixture.StatePath))).Count-ne0){throw 'I5 RED finalization failure did not restore before bytes'}
        $failedEvidence=Join-Path $finalizationFixture.Root "evidence\runs\$($finalizationInventory.generationId)"
        $failedManifest=Get-Content -Raw (Join-Path $failedEvidence 'manifest.json')|ConvertFrom-Json -Depth 64
        if($failedManifest.status-cne'rolled-back'-or$failedManifest.recovery.required-ne$false){throw 'I5 RED finalization failure lacks rolled-back terminal evidence'}
    } finally {Remove-Item -LiteralPath $finalizationFixture.Root -Recurse -Force -ErrorAction SilentlyContinue}

    $blockedFixture=New-Fixture
    try {
        $blockedInventory=Read-Result (Invoke-Entry @('-Mode','Inventory','-FixtureRoot',$blockedFixture.Root,'-Json'))
        $blocked=Invoke-Entry @('-Mode','Repair','-FixtureRoot',$blockedFixture.Root,'-InventoryGeneration',$blockedInventory.generationId,'-ApprovedMappingHash',$blockedInventory.approvedMappingHash,'-Json') @{CODEX_STATE_PATH_REPAIR_FIXTURE_THIRD_PARTY_AFTER_APPLY='1'}
        if($blocked.ExitCode-eq0){throw 'I5 RED third-party finalization drift was accepted'}
        $blockedBytes=[IO.File]::ReadAllBytes($blockedFixture.StatePath)
        $blockedEvidence=Join-Path $blockedFixture.Root "evidence\runs\$($blockedInventory.generationId)"
        $blockedManifest=Get-Content -Raw (Join-Path $blockedEvidence 'manifest.json')|ConvertFrom-Json -Depth 64
        if($blockedManifest.status-cne'rollback-blocked'-or$blockedManifest.recovery.required-ne$true-or$blockedManifest.recovery.reason-cne'third-party-state-drift'){throw 'I5 RED third-party drift lacks rollback-blocked evidence'}
        $blockedRestore=Invoke-Entry @('-Mode','Restore','-FixtureRoot',$blockedFixture.Root,'-EvidencePath',$blockedEvidence,'-Json')
        if($blockedRestore.ExitCode-eq0){throw 'I5 RED rollback-blocked evidence restored'}
        if(@(Compare-Object $blockedBytes ([IO.File]::ReadAllBytes($blockedFixture.StatePath))).Count-ne0){throw 'I5 RED rollback-blocked Restore changed third-party bytes'}
    } finally {Remove-Item -LiteralPath $blockedFixture.Root -Recurse -Force -ErrorAction SilentlyContinue}

    $forgedFixture=New-Fixture
    try {
        $forgedInventory=Read-Result (Invoke-Entry @('-Mode','Inventory','-FixtureRoot',$forgedFixture.Root,'-Json'))
        $forgedRepair=Read-Result (Invoke-Entry @('-Mode','Repair','-FixtureRoot',$forgedFixture.Root,'-InventoryGeneration',$forgedInventory.generationId,'-ApprovedMappingHash',$forgedInventory.approvedMappingHash,'-Json'))
        $afterBytes=[IO.File]::ReadAllBytes($forgedFixture.StatePath)
        $backupPath=Join-Path $forgedRepair.evidencePath 'before.bin'
        $backupBytes=[IO.File]::ReadAllBytes($backupPath)
        [IO.File]::WriteAllBytes($backupPath,[Text.UTF8Encoding]::new($false).GetBytes('forged-backup'))
        $forgedBackupRestore=Invoke-Entry @('-Mode','Restore','-FixtureRoot',$forgedFixture.Root,'-EvidencePath',$forgedRepair.evidencePath,'-Json')
        if($forgedBackupRestore.ExitCode-eq0){throw 'I5 RED forged backup restored'}
        if(@(Compare-Object $afterBytes ([IO.File]::ReadAllBytes($forgedFixture.StatePath))).Count-ne0){throw 'I5 RED forged backup changed state'}
        [IO.File]::WriteAllBytes($backupPath,$backupBytes)
        $manifestPath=Join-Path $forgedRepair.evidencePath 'manifest.json'
        $forgedManifest=Get-Content -Raw $manifestPath|ConvertFrom-Json -Depth 64
        $forgedManifest.afterSha256='0'*64
        [IO.File]::WriteAllText($manifestPath,($forgedManifest|ConvertTo-Json -Depth 64 -Compress),[Text.UTF8Encoding]::new($false))
        $forgedManifestRestore=Invoke-Entry @('-Mode','Restore','-FixtureRoot',$forgedFixture.Root,'-EvidencePath',$forgedRepair.evidencePath,'-Json')
        if($forgedManifestRestore.ExitCode-eq0){throw 'I5 RED forged manifest restored'}
        if(@(Compare-Object $afterBytes ([IO.File]::ReadAllBytes($forgedFixture.StatePath))).Count-ne0){throw 'I5 RED forged manifest changed state'}
    } finally {Remove-Item -LiteralPath $forgedFixture.Root -Recurse -Force -ErrorAction SilentlyContinue}
}
'I6'{$f=New-Fixture;$i=Read-Result (Invoke-Entry @('-Mode','Inventory','-FixtureRoot',$f.Root,'-Json'));$before=[IO.File]::ReadAllBytes($f.StatePath);$outside=Join-Path $FixtureParent ($f.Root.Split('\')[-1]+'-outside');New-Item -ItemType Directory $outside|Out-Null;try{$r=Invoke-Entry @('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration',$i.generationId,'-ApprovedMappingHash',$i.approvedMappingHash,'-Json') @{CODEX_STATE_PATH_REPAIR_FIXTURE_SWAP_EVIDENCE_PARENT=$outside};if($r.ExitCode-eq0){throw 'I6 RED evidence ancestor swap accepted'};if(@(Get-ChildItem $outside -Force).Count-ne0){throw 'I6 RED outside mutated'};if(@(Compare-Object $before ([IO.File]::ReadAllBytes($f.StatePath))).Count-ne0){throw 'I6 RED evidence rejection changed state'}}finally{Remove-Item $outside -Recurse -Force -ErrorAction SilentlyContinue}}
'I7'{
    $f=New-Fixture
    $i=Read-Result (Invoke-Entry @('-Mode','Inventory','-FixtureRoot',$f.Root,'-Json'))
    $artifactPath=[string]$i.approvalArtifactPath
    $artifact=Get-Content -Raw -LiteralPath $artifactPath|ConvertFrom-Json -Depth 64
    $artifact.entries=@()
    [IO.File]::WriteAllText($artifactPath,($artifact|ConvertTo-Json -Depth 64 -Compress),[Text.UTF8Encoding]::new($false))
    $before=[IO.File]::ReadAllBytes($f.StatePath)
    $r=Invoke-Entry @('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration',$i.generationId,'-ApprovedMappingHash',$i.approvedMappingHash,'-Json')
    Assert-SingleJsonFailure $r 'I7 trimmed approval artifact'
    if(@(Compare-Object $before ([IO.File]::ReadAllBytes($f.StatePath))).Count-ne0){throw 'I7 RED trimmed approval changed state'}
    $claims=Join-Path $f.Root 'evidence\.claims'
    if((Test-Path $claims)-and@(Get-ChildItem $claims -Force).Count-ne0){throw 'I7 RED trimmed approval created a claim'}

    Remove-Item -LiteralPath $f.Root -Recurse -Force;$f=New-Fixture
    $i=Read-Result (Invoke-Entry @('-Mode','Inventory','-FixtureRoot',$f.Root,'-Json'))
    $artifactText=Get-Content -Raw -LiteralPath ([string]$i.approvalArtifactPath)
    $duplicate=$artifactText -replace '"state":"fresh"','"state":"fresh","state":"fresh"'
    [IO.File]::WriteAllText([string]$i.approvalArtifactPath,$duplicate,[Text.UTF8Encoding]::new($false))
    $before=[IO.File]::ReadAllBytes($f.StatePath)
    $r=Invoke-Entry @('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration',$i.generationId,'-ApprovedMappingHash',$i.approvedMappingHash,'-Json')
    Assert-SingleJsonFailure $r 'I7 duplicate-key approval artifact'
    if(@(Compare-Object $before ([IO.File]::ReadAllBytes($f.StatePath))).Count-ne0){throw 'I7 RED duplicate-key approval changed state'}
}
'I8'{
    $f=New-Fixture
    $i=Read-Result (Invoke-Entry @('-Mode','Inventory','-FixtureRoot',$f.Root,'-Json'))
    $candidate=Join-Path $f.CandidateRoot 'safe';$replacement=Join-Path $f.CandidateRoot 'safe-new'
    New-Item -ItemType Directory -Path $replacement|Out-Null;Remove-Item -LiteralPath $candidate -Force;Move-Item -LiteralPath $replacement -Destination $candidate
    $before=[IO.File]::ReadAllBytes($f.StatePath)
    $r=Invoke-Entry @('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration',$i.generationId,'-ApprovedMappingHash',$i.approvedMappingHash,'-Json')
    Assert-SingleJsonFailure $r 'I8 directory candidate identity drift'
    if(@(Compare-Object $before ([IO.File]::ReadAllBytes($f.StatePath))).Count-ne0){throw 'I8 RED directory identity drift changed state'}

    Remove-Item -LiteralPath $f.Root -Recurse -Force;$f=New-Fixture -FileCandidate
    $i=Read-Result (Invoke-Entry @('-Mode','Inventory','-FixtureRoot',$f.Root,'-Json'))
    $candidate=Join-Path $f.CandidateRoot 'safe-file';$replacement=Join-Path $f.CandidateRoot 'safe-file-new'
    [IO.File]::WriteAllBytes($replacement,[IO.File]::ReadAllBytes($candidate));[IO.File]::Move($replacement,$candidate,$true)
    $before=[IO.File]::ReadAllBytes($f.StatePath)
    $r=Invoke-Entry @('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration',$i.generationId,'-ApprovedMappingHash',$i.approvedMappingHash,'-Json')
    Assert-SingleJsonFailure $r 'I8 file candidate identity drift'
    if(@(Compare-Object $before ([IO.File]::ReadAllBytes($f.StatePath))).Count-ne0){throw 'I8 RED file identity drift changed state'}

    Remove-Item -LiteralPath $f.Root -Recurse -Force;$f=New-Fixture -FileCandidate
    $i=Read-Result (Invoke-Entry @('-Mode','Inventory','-FixtureRoot',$f.Root,'-Json'))
    $before=[IO.File]::ReadAllBytes($f.StatePath);$candidateBytes=[IO.File]::ReadAllBytes((Join-Path $f.CandidateRoot 'safe-file'))
    $r=Invoke-Entry @('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration',$i.generationId,'-ApprovedMappingHash',$i.approvedMappingHash,'-Json') @{CODEX_STATE_PATH_REPAIR_FIXTURE_POSIX_REPLACE_CANDIDATE='safe-file'}
    Assert-SingleJsonFailure $r 'I8 class-65 candidate replacement'
    if(@(Compare-Object $before ([IO.File]::ReadAllBytes($f.StatePath))).Count-ne0){throw 'I8 RED class-65 candidate attack changed state'}
    if(@(Compare-Object $candidateBytes ([IO.File]::ReadAllBytes((Join-Path $f.CandidateRoot 'safe-file')))).Count-ne0){throw 'I8 RED class-65 candidate attack replaced candidate'}
}
'I9'{
    $f=New-Fixture
    $i=Read-Result (Invoke-Entry @('-Mode','Inventory','-FixtureRoot',$f.Root,'-Json'))
    $repair=Read-Result (Invoke-Entry @('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration',$i.generationId,'-ApprovedMappingHash',$i.approvedMappingHash,'-Json'))
    $after=[IO.File]::ReadAllBytes($f.StatePath);$replacement=Join-Path $f.Home 'same-bytes-state.json'
    [IO.File]::WriteAllBytes($replacement,$after);[IO.File]::Move($replacement,$f.StatePath,$true)
    $current=[IO.File]::ReadAllBytes($f.StatePath)
    $r=Invoke-Entry @('-Mode','Restore','-FixtureRoot',$f.Root,'-EvidencePath',$repair.evidencePath,'-Json')
    Assert-SingleJsonFailure $r 'I9 same-bytes new-identity Restore'
    if(@(Compare-Object $current ([IO.File]::ReadAllBytes($f.StatePath))).Count-ne0){throw 'I9 RED Restore overwrote same-bytes new identity'}

    Remove-Item -LiteralPath $f.Root -Recurse -Force;$f=New-Fixture
    $i=Read-Result (Invoke-Entry @('-Mode','Inventory','-FixtureRoot',$f.Root,'-Json'))
    $r=Invoke-Entry @('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration',$i.generationId,'-ApprovedMappingHash',$i.approvedMappingHash,'-Json') @{CODEX_STATE_PATH_REPAIR_FIXTURE_REPLACE_TARGET_AFTER_APPLY='1'}
    Assert-SingleJsonFailure $r 'I9 same-bytes new-identity automatic rollback'
    $evidence=Join-Path $f.Root "evidence\runs\$($i.generationId)"
    $manifest=Get-Content -Raw (Join-Path $evidence 'manifest.json')|ConvertFrom-Json -Depth 64
    if($manifest.status-cne'rollback-blocked'-or$manifest.recovery.reason-cne'third-party-state-identity-drift'){throw 'I9 RED automatic rollback did not record identity drift'}
}
'I10'{
    $f=New-Fixture
    Assert-SingleJsonFailure (Invoke-Entry @('-Mode','NotAMode','-FixtureRoot',$f.Root,'-Json')) 'I10 invalid mode'
    Assert-SingleJsonFailure (Invoke-Entry @('-Mode','Inventory','-FixtureRoot',$f.Root,'-EvidencePath',(Join-Path $f.Root 'unused'),'-Json')) 'I10 inventory unrelated EvidencePath'
    Assert-SingleJsonFailure (Invoke-Entry @('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration','approval-v1-00000000000000000000000000000000','-ApprovedMappingHash',('0'*64),'-EvidencePath',(Join-Path $f.Root 'unused'),'-Json')) 'I10 repair unrelated EvidencePath'
    Assert-SingleJsonFailure (Invoke-Entry @('-Mode','Restore','-FixtureRoot',$f.Root,'-EvidencePath',(Join-Path $f.Root 'missing'),'-InventoryGeneration','approval-v1-00000000000000000000000000000000','-Json')) 'I10 restore unrelated InventoryGeneration'
}
'I11'{
    $f=New-Fixture
    $before=[IO.File]::ReadAllBytes($f.StatePath)
    $i=Read-Result (Invoke-Entry @('-Mode','Inventory','-FixtureRoot',$f.Root,'-Json'))
    $repair=Read-Result (Invoke-Entry @('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration',$i.generationId,'-ApprovedMappingHash',$i.approvedMappingHash,'-Json'))
    Remove-Item -LiteralPath $repair.evidencePath -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $f.Root "evidence\.claims\$($i.generationId).json") -Force
    [IO.File]::WriteAllBytes($f.StatePath,$before)
    $r=Invoke-Entry @('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration',$i.generationId,'-ApprovedMappingHash',$i.approvedMappingHash,'-Json')
    Assert-SingleJsonFailure $r 'I11 deleted-run-and-claim replay'
    if(@(Compare-Object $before ([IO.File]::ReadAllBytes($f.StatePath))).Count-ne0){throw 'I11 RED replay changed state'}
}
'I12'{
    $f=New-Fixture -FileCandidate
    $candidate=Join-Path $f.CandidateRoot 'safe-file'
    $guard=[CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire($f.CandidateRoot,$f.CandidateRoot,$false)
    $lease=$guard.AcquireReadOnlyFileLease($candidate)
    try{
        $writeBlocked=$false;try{$stream=[IO.File]::Open($candidate,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite);$stream.Dispose()}catch{$writeBlocked=$true};if(-not$writeBlocked){throw 'I12 read-only lease allowed write'}
        $deleteBlocked=$false;try{[IO.File]::Delete($candidate)}catch{$deleteBlocked=$true};if(-not$deleteBlocked){throw 'I12 read-only lease allowed delete'}
        $attackPath=Join-Path $f.CandidateRoot '.lease-class65.tmp';$attack=$guard.CreateTempFile($attackPath);$renameBlocked=$false
        try{$attack.WriteAndFlush([byte[]](9,9,9,9));try{$attack.RenameTo($candidate,$true)}catch{$renameBlocked=$true}}finally{$attack.Dispose();if([IO.File]::Exists($attackPath)){[IO.File]::Delete($attackPath)}}
        if(-not$renameBlocked){throw 'I12 read-only lease allowed class-65 replace'}
        $stateBytes=[IO.File]::ReadAllBytes($f.StatePath);$stateSha=Get-CodexHookBytesSha256 -Bytes $stateBytes;$changedBytes=[Text.UTF8Encoding]::new($false).GetBytes('{"leaseCanary":true}');$changedSha=Get-CodexHookBytesSha256 -Bytes $changedBytes
        Set-CodexHookAtomicFileBytesWithCapability -Path $f.StatePath -Bytes $changedBytes -ExpectedExists $true -ExpectedSha256 $stateSha -AfterSha256 $changedSha -CapabilityRoot $f.Home -AllowedExactPaths @($f.StatePath) -Scope 'I12 independent state publish'
        if((Get-FileHash $f.StatePath -Algorithm SHA256).Hash.ToLowerInvariant()-cne$changedSha){throw 'I12 independent state publish failed while candidate lease held'}
    }finally{$lease.Dispose();$guard.Dispose()}
    $releaseGuard=[CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire($f.CandidateRoot,$f.CandidateRoot,$false);$releasePath=Join-Path $f.CandidateRoot '.lease-release.tmp';$release=$releaseGuard.CreateTempFile($releasePath)
    try{$release.WriteAndFlush([byte[]](7,7,7,7));$release.RenameTo($candidate,$true)}finally{$release.Dispose();$releaseGuard.Dispose();if([IO.File]::Exists($releasePath)){[IO.File]::Delete($releasePath)}}
    if(@(Compare-Object ([byte[]](7,7,7,7)) ([IO.File]::ReadAllBytes($candidate))).Count-ne0){throw 'I12 replacement did not succeed after lease release'}
}
'I13'{
    $f=New-Fixture -NoOp
    $before=[IO.File]::ReadAllBytes($f.StatePath)
    $i=Read-Result (Invoke-Entry @('-Mode','Inventory','-FixtureRoot',$f.Root,'-Json'))
    $r=Read-Result (Invoke-Entry @('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration',$i.generationId,'-ApprovedMappingHash',$i.approvedMappingHash,'-Json'))
    if($r.changed-ne$false-or$r.noOp-ne$true-or$null-ne$r.evidencePath){throw "I13 RED no-op Repair produced evidence: $($r|ConvertTo-Json -Compress)"}
    if(@(Compare-Object $before ([IO.File]::ReadAllBytes($f.StatePath))).Count-ne0){throw 'I13 RED no-op Repair changed state'}
    if(Test-Path -LiteralPath (Join-Path $f.Root "evidence\runs\$($i.generationId)")){throw 'I13 RED no-op Repair created a run'}
    $again=Read-Result (Invoke-Entry @('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration',$i.generationId,'-ApprovedMappingHash',$i.approvedMappingHash,'-Json'))
    if($again.changed-ne$false-or$again.noOp-ne$true-or$null-ne$again.evidencePath){throw 'I13 RED repeated no-op Repair was not idempotent'}

}
'I14'{
    $f=New-Fixture
    $before=[IO.File]::ReadAllBytes($f.StatePath)
    $i=Read-Result (Invoke-Entry @('-Mode','Inventory','-FixtureRoot',$f.Root,'-Json'))
    $applyCrash=Invoke-Entry @('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration',$i.generationId,'-ApprovedMappingHash',$i.approvedMappingHash,'-Json') @{CODEX_STATE_PATH_REPAIR_FIXTURE_FAILFAST_AFTER_APPLY_RENAME='1'}
    if($applyCrash.ExitCode-eq0){throw 'I14 RED apply hard-crash seam did not terminate the child process'}
    $evidence=Join-Path $f.Root "evidence\runs\$($i.generationId)"
    if(-not(Test-Path -LiteralPath $evidence -PathType Container)){throw 'I14 RED apply crash left no recoverable evidence'}
    $restore=Invoke-Entry @('-Mode','Restore','-FixtureRoot',$f.Root,'-EvidencePath',$evidence,'-Json')
    if($restore.ExitCode-ne0){throw "I14 RED apply crash could not be recovered: $($restore.Text)"}
    if(@(Compare-Object $before ([IO.File]::ReadAllBytes($f.StatePath))).Count-ne0){throw 'I14 RED apply crash recovery did not restore before bytes'}
}
'I15'{
    $f=New-Fixture
    $before=[IO.File]::ReadAllBytes($f.StatePath)
    $i=Read-Result (Invoke-Entry @('-Mode','Inventory','-FixtureRoot',$f.Root,'-Json'))
    $repair=Read-Result (Invoke-Entry @('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration',$i.generationId,'-ApprovedMappingHash',$i.approvedMappingHash,'-Json'))
    $restoreCrash=Invoke-Entry @('-Mode','Restore','-FixtureRoot',$f.Root,'-EvidencePath',$repair.evidencePath,'-Json') @{CODEX_STATE_PATH_REPAIR_FIXTURE_FAILFAST_AFTER_RESTORE_RENAME='1'}
    if($restoreCrash.ExitCode-eq0){throw 'I15 RED restore hard-crash seam did not terminate the child process'}
    $retry=Invoke-Entry @('-Mode','Restore','-FixtureRoot',$f.Root,'-EvidencePath',$repair.evidencePath,'-Json')
    if($retry.ExitCode-ne0){throw "I15 RED restore hard crash was not resumable: $($retry.Text)"}
    if(@(Compare-Object $before ([IO.File]::ReadAllBytes($f.StatePath))).Count-ne0){throw 'I15 RED restore hard crash retry did not converge'}
}
'I16'{
    $f=New-Fixture
    $before=[IO.File]::ReadAllBytes($f.StatePath)
    $i=Read-Result (Invoke-Entry @('-Mode','Inventory','-FixtureRoot',$f.Root,'-Json'))
    $ledgerRoot=Join-Path $f.Root 'evidence\.approval-ledger'
    if(-not(Test-Path -LiteralPath (Join-Path $ledgerRoot 'head.json') -PathType Leaf)){throw 'I16 RED fixed authenticated ledger head missing after approval creation'}
    $repair=Read-Result (Invoke-Entry @('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration',$i.generationId,'-ApprovedMappingHash',$i.approvedMappingHash,'-Json'))
    Remove-Item -LiteralPath $repair.evidencePath -Recurse -Force
    foreach($path in @(
        (Join-Path $f.Root "evidence\.claims\$($i.generationId).json"),
        (Join-Path $f.Root "evidence\.consumed-approvals\$($i.generationId).json")
    )){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force}}
    [IO.File]::WriteAllBytes($f.StatePath,$before)
    $replay=Invoke-Entry @('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration',$i.generationId,'-ApprovedMappingHash',$i.approvedMappingHash,'-Json')
    Assert-SingleJsonFailure $replay 'I16 deleted run/claim/consumed replay'
    if(@(Compare-Object $before ([IO.File]::ReadAllBytes($f.StatePath))).Count-ne0){throw 'I16 RED replay changed state'}

    Remove-Item -LiteralPath $ledgerRoot -Recurse -Force
    $missingLedger=Invoke-Entry @('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration',$i.generationId,'-ApprovedMappingHash',$i.approvedMappingHash,'-Json')
    Assert-SingleJsonFailure $missingLedger 'I16 missing fixed ledger with approval history'

    Remove-Item -LiteralPath $f.Root -Recurse -Force;$f=New-Fixture
    $before=[IO.File]::ReadAllBytes($f.StatePath)
    $i=Read-Result (Invoke-Entry @('-Mode','Inventory','-FixtureRoot',$f.Root,'-Json'))
    $ledgerRoot=Join-Path $f.Root 'evidence\.approval-ledger'
    [IO.File]::WriteAllText((Join-Path $ledgerRoot 'unexpected.json'),'{}',[Text.UTF8Encoding]::new($false))
    $unknown=Invoke-Entry @('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration',$i.generationId,'-ApprovedMappingHash',$i.approvedMappingHash,'-Json')
    Assert-SingleJsonFailure $unknown 'I16 unknown fixed ledger item'
    if(@(Compare-Object $before ([IO.File]::ReadAllBytes($f.StatePath))).Count-ne0){throw 'I16 RED unknown ledger item changed state'}
}
'I17'{
    [byte[]]$entropy=[Text.UTF8Encoding]::new($false).GetBytes('codex-state-path-repair-v1/evidence-attestation')
    foreach($vector in @(
        [pscustomobject]@{label='duplicate-key';bytes=[Text.UTF8Encoding]::new($false).GetBytes('{"artifactType":"x","artifactType":"x","generatedAtUtc":"2026-07-14T00:00:00Z"}');mustFail=$true},
        [pscustomobject]@{label='invalid-utf8';bytes=[byte[]](0xff,0xfe,0xfd);mustFail=$true},
        [pscustomobject]@{label='date-kind';bytes=[Text.UTF8Encoding]::new($false).GetBytes('{"generatedAtUtc":"2026-07-14T00:00:00Z"}');mustFail=$false}
    )){
        [byte[]]$cipher=[Security.Cryptography.ProtectedData]::Protect([byte[]]$vector.bytes,$entropy,[Security.Cryptography.DataProtectionScope]::CurrentUser)
        $envelope=[pscustomobject]@{protection='dpapi-current-user-v1';trustBoundary='same-windows-user';data=[Convert]::ToBase64String($cipher)}
        $failed=$false;$payload=$null;$failureMessage=$null
        try{$payload=Unprotect-CodexRepairAttestation -Envelope $envelope}catch{$failed=$true;$failureMessage=$_.Exception.Message}
        if($vector.mustFail-and-not$failed){throw "I17 RED $($vector.label) attestation accepted"}
        if(-not$vector.mustFail-and($failed-or$payload.generatedAtUtc-isnot[string])){$payloadType=if($null-eq$payload){'null'}else{$payload.generatedAtUtc.GetType().FullName};throw "I17 RED attestation date was not preserved as string: failed=$failed type=$payloadType error=$failureMessage"}
    }
}
'I18'{
    $f=New-Fixture
    $before=[IO.File]::ReadAllBytes($f.StatePath)
    $i=Read-Result (Invoke-Entry @('-Mode','Inventory','-FixtureRoot',$f.Root,'-Json'))
    $crash=Invoke-Entry @('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration',$i.generationId,'-ApprovedMappingHash',$i.approvedMappingHash,'-Json') @{
        CODEX_STATE_PATH_REPAIR_FIXTURE_FAIL_COMPLETED='1'
        CODEX_STATE_PATH_REPAIR_FIXTURE_FAILFAST_AFTER_ROLLBACK_RENAME='1'
    }
    if($crash.ExitCode-eq0){throw 'I18 RED automatic rollback crash did not fail the child'}
    $evidence=Join-Path $f.Root "evidence\runs\$($i.generationId)"
    $manifest=Get-Content -Raw -LiteralPath (Join-Path $evidence 'manifest.json')|ConvertFrom-Json -Depth 64
    if($manifest.status-cne'restoring-intent'){throw "I18 RED automatic rollback did not stop at authenticated restoring-intent: $($manifest.status)"}
    $retry=Invoke-Entry @('-Mode','Restore','-FixtureRoot',$f.Root,'-EvidencePath',$evidence,'-Json')
    if($retry.ExitCode-ne0){throw "I18 RED automatic rollback crash was not resumable: $($retry.Text)"}
    if(@(Compare-Object $before ([IO.File]::ReadAllBytes($f.StatePath))).Count-ne0){throw 'I18 RED automatic rollback crash retry did not converge'}
}
'I19'{
    $f=New-Fixture;$before=[IO.File]::ReadAllBytes($f.StatePath)
    $i=Read-Result (Invoke-Entry @('-Mode','Inventory','-FixtureRoot',$f.Root,'-Json'))
    $crash=Invoke-Entry @('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration',$i.generationId,'-ApprovedMappingHash',$i.approvedMappingHash,'-Json') @{CODEX_STATE_PATH_REPAIR_FIXTURE_FAILFAST_AFTER_APPLY_INTENT_CREATE='1'}
    if($crash.ExitCode-eq0){throw 'I19 RED apply-intent pre-manifest seam did not terminate the child'}
    $evidence=Join-Path $f.Root "evidence\runs\$($i.generationId)";$manifest=Get-Content -Raw (Join-Path $evidence 'manifest.json')|ConvertFrom-Json -Depth 64
    if($manifest.status-cne'applying'-or-not(Test-Path -LiteralPath (Join-Path $evidence 'apply-intent.json') -PathType Leaf)){throw 'I19 RED did not leave applying plus orphan apply-intent'}
    $retry=Invoke-Entry @('-Mode','Restore','-FixtureRoot',$f.Root,'-EvidencePath',$evidence,'-Json');if($retry.ExitCode-ne0){throw "I19 RED orphan apply-intent was not recoverable: $($retry.Text)"}
    if(@(Compare-Object $before ([IO.File]::ReadAllBytes($f.StatePath))).Count-ne0){throw 'I19 RED orphan apply-intent recovery changed before bytes'}
    if(@(Get-ChildItem -LiteralPath (Split-Path -Parent $f.StatePath) -File -Filter '.codex-hook-*.tmp').Count-ne0){throw 'I19 RED orphan apply-intent recovery left a prepared temp'}
}
'I20'{
    $f=New-Fixture;$before=[IO.File]::ReadAllBytes($f.StatePath)
    $i=Read-Result (Invoke-Entry @('-Mode','Inventory','-FixtureRoot',$f.Root,'-Json'));$repair=Read-Result (Invoke-Entry @('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration',$i.generationId,'-ApprovedMappingHash',$i.approvedMappingHash,'-Json'))
    $crash=Invoke-Entry @('-Mode','Restore','-FixtureRoot',$f.Root,'-EvidencePath',$repair.evidencePath,'-Json') @{CODEX_STATE_PATH_REPAIR_FIXTURE_FAILFAST_AFTER_RESTORE_INTENT_CREATE='1'}
    if($crash.ExitCode-eq0){throw 'I20 RED manual restore-intent pre-manifest seam did not terminate the child'}
    $manifest=Get-Content -Raw (Join-Path $repair.evidencePath 'manifest.json')|ConvertFrom-Json -Depth 64
    if($manifest.status-cne'completed'-or-not(Test-Path -LiteralPath (Join-Path $repair.evidencePath 'restore-intent.json') -PathType Leaf)){throw 'I20 RED did not leave completed plus orphan restore-intent'}
    $retry=Invoke-Entry @('-Mode','Restore','-FixtureRoot',$f.Root,'-EvidencePath',$repair.evidencePath,'-Json');if($retry.ExitCode-ne0){throw "I20 RED orphan manual restore-intent was not recoverable: $($retry.Text)"}
    if(@(Compare-Object $before ([IO.File]::ReadAllBytes($f.StatePath))).Count-ne0){throw 'I20 RED orphan manual restore intent did not converge'}
}
'I21'{
    $f=New-Fixture;$before=[IO.File]::ReadAllBytes($f.StatePath)
    $i=Read-Result (Invoke-Entry @('-Mode','Inventory','-FixtureRoot',$f.Root,'-Json'))
    $crash=Invoke-Entry @('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration',$i.generationId,'-ApprovedMappingHash',$i.approvedMappingHash,'-Json') @{CODEX_STATE_PATH_REPAIR_FIXTURE_FAIL_COMPLETED='1';CODEX_STATE_PATH_REPAIR_FIXTURE_FAILFAST_AFTER_ROLLBACK_INTENT_CREATE='1'}
    if($crash.ExitCode-eq0){throw 'I21 RED automatic rollback intent pre-manifest seam did not fail the child'}
    $evidence=Join-Path $f.Root "evidence\runs\$($i.generationId)";$manifest=Get-Content -Raw (Join-Path $evidence 'manifest.json')|ConvertFrom-Json -Depth 64
    if($manifest.status-cnotin@('applying-intent','completed')-or-not(Test-Path -LiteralPath (Join-Path $evidence 'restore-intent.json') -PathType Leaf)){throw "I21 RED automatic rollback orphan state invalid: $($manifest.status)"}
    $retry=Invoke-Entry @('-Mode','Restore','-FixtureRoot',$f.Root,'-EvidencePath',$evidence,'-Json');if($retry.ExitCode-ne0){throw "I21 RED orphan automatic rollback intent was not recoverable: $($retry.Text)"}
    if(@(Compare-Object $before ([IO.File]::ReadAllBytes($f.StatePath))).Count-ne0){throw 'I21 RED orphan automatic rollback intent did not converge'}
}
'I22'{
    $f=New-Fixture;$before=[IO.File]::ReadAllBytes($f.StatePath)
    $i=Read-Result (Invoke-Entry @('-Mode','Inventory','-FixtureRoot',$f.Root,'-Json'));$repair=Read-Result (Invoke-Entry @('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration',$i.generationId,'-ApprovedMappingHash',$i.approvedMappingHash,'-Json'))
    $crash=Invoke-Entry @('-Mode','Restore','-FixtureRoot',$f.Root,'-EvidencePath',$repair.evidencePath,'-Json') @{CODEX_STATE_PATH_REPAIR_FIXTURE_FAILFAST_AFTER_RESTORE_ATTESTATION_CREATE='1'}
    if($crash.ExitCode-eq0){throw 'I22 RED terminal restore attestation pre-manifest seam did not terminate the child'}
    $manifest=Get-Content -Raw (Join-Path $repair.evidencePath 'manifest.json')|ConvertFrom-Json -Depth 64
    if($manifest.status-cne'restoring-intent'-or-not(Test-Path -LiteralPath (Join-Path $repair.evidencePath 'restore-attestation.json') -PathType Leaf)){throw 'I22 RED did not leave restoring-intent plus orphan terminal attestation'}
    $retry=Invoke-Entry @('-Mode','Restore','-FixtureRoot',$f.Root,'-EvidencePath',$repair.evidencePath,'-Json');if($retry.ExitCode-ne0){throw "I22 RED orphan terminal attestation was not recoverable: $($retry.Text)"}
    if(@(Compare-Object $before ([IO.File]::ReadAllBytes($f.StatePath))).Count-ne0){throw 'I22 RED terminal attestation retry did not converge'}
}
'I23'{
    $f=New-Fixture
    $i=Read-Result (Invoke-Entry @('-Mode','Inventory','-FixtureRoot',$f.Root,'-Json'))
    $crash=Invoke-Entry @('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration',$i.generationId,'-ApprovedMappingHash',$i.approvedMappingHash,'-Json') @{CODEX_STATE_PATH_REPAIR_FIXTURE_FAILFAST_AFTER_LEDGER_RECORD_CREATE='1'}
    if($crash.ExitCode-eq0){throw 'I23 RED ledger record pre-head seam did not terminate the child'}
    $ledger=Join-Path $f.Root 'evidence\.approval-ledger';$head=Get-Content -Raw (Join-Path $ledger 'head.json')|ConvertFrom-Json -Depth 16
    if(@(Get-ChildItem $ledger -File -Filter 'entry-*.json').Count-ne1){throw 'I23 RED did not leave exactly one pending ledger record'}
    $retry=Invoke-Entry @('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration',$i.generationId,'-ApprovedMappingHash',$i.approvedMappingHash,'-Json');if($retry.ExitCode-ne0){throw "I23 RED valid pending ledger record was not promoted: $($retry.Text)"}

    Remove-Item -LiteralPath $f.Root -Recurse -Force;$f=New-Fixture;$before=[IO.File]::ReadAllBytes($f.StatePath)
    $i=Read-Result (Invoke-Entry @('-Mode','Inventory','-FixtureRoot',$f.Root,'-Json'))
    [void](Invoke-Entry @('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration',$i.generationId,'-ApprovedMappingHash',$i.approvedMappingHash,'-Json') @{CODEX_STATE_PATH_REPAIR_FIXTURE_FAILFAST_AFTER_LEDGER_RECORD_CREATE='1'})
    $ledger=Join-Path $f.Root 'evidence\.approval-ledger';$pendingFile=Get-ChildItem $ledger -File -Filter 'entry-*.json'|Select-Object -First 1
    [IO.File]::WriteAllText($pendingFile.FullName,'{"tampered":true}',[Text.UTF8Encoding]::new($false))
    Assert-SingleJsonFailure (Invoke-Entry @('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration',$i.generationId,'-ApprovedMappingHash',$i.approvedMappingHash,'-Json')) 'I23 tampered pending ledger record'
    if(@(Compare-Object $before ([IO.File]::ReadAllBytes($f.StatePath))).Count-ne0){throw 'I23 RED tampered pending record changed state'}

    Remove-Item -LiteralPath $f.Root -Recurse -Force;$f=New-Fixture;$before=[IO.File]::ReadAllBytes($f.StatePath)
    $i=Read-Result (Invoke-Entry @('-Mode','Inventory','-FixtureRoot',$f.Root,'-Json'))
    [void](Invoke-Entry @('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration',$i.generationId,'-ApprovedMappingHash',$i.approvedMappingHash,'-Json') @{CODEX_STATE_PATH_REPAIR_FIXTURE_FAILFAST_AFTER_LEDGER_RECORD_CREATE='1'})
    $ledger=Join-Path $f.Root 'evidence\.approval-ledger';$pendingFile=Get-ChildItem $ledger -File -Filter 'entry-*.json'|Select-Object -First 1
    Copy-Item -LiteralPath $pendingFile.FullName -Destination (Join-Path $ledger 'entry-0000000000000002.json')
    Assert-SingleJsonFailure (Invoke-Entry @('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration',$i.generationId,'-ApprovedMappingHash',$i.approvedMappingHash,'-Json')) 'I23 multiple pending ledger records'
    if(@(Compare-Object $before ([IO.File]::ReadAllBytes($f.StatePath))).Count-ne0){throw 'I23 RED multiple pending records changed state'}
}
'I24'{
    $f=New-Fixture;$before=[IO.File]::ReadAllBytes($f.StatePath)
    $i=Read-Result (Invoke-Entry @('-Mode','Inventory','-FixtureRoot',$f.Root,'-Json'));$repair=Read-Result (Invoke-Entry @('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration',$i.generationId,'-ApprovedMappingHash',$i.approvedMappingHash,'-Json'))
    $failed=Invoke-Entry @('-Mode','Restore','-FixtureRoot',$f.Root,'-EvidencePath',$repair.evidencePath,'-Json') @{CODEX_STATE_PATH_REPAIR_FIXTURE_THROW_ON_RESTORE_RENAME='1'}
    if($failed.ExitCode-eq0){throw 'I24 RED ordinary restore rename failure seam was ignored'}
    $manifest=Get-Content -Raw (Join-Path $repair.evidencePath 'manifest.json')|ConvertFrom-Json -Depth 64
    if($manifest.status-cne'restoring-intent'){throw "I24 RED ordinary restore rename failure did not preserve restoring-intent: $($manifest.status)"}
    if(@(Get-ChildItem -LiteralPath (Split-Path -Parent $f.StatePath) -File -Filter '.codex-hook-*.tmp').Count-ne1){throw 'I24 RED ordinary restore rename failure did not preserve exactly one prepared temp'}
    $retry=Invoke-Entry @('-Mode','Restore','-FixtureRoot',$f.Root,'-EvidencePath',$repair.evidencePath,'-Json');if($retry.ExitCode-ne0){throw "I24 RED preserved restore intent was not resumable: $($retry.Text)"}
    if(@(Compare-Object $before ([IO.File]::ReadAllBytes($f.StatePath))).Count-ne0){throw 'I24 RED resumed restore did not converge'}
    if(@(Get-ChildItem -LiteralPath (Split-Path -Parent $f.StatePath) -File -Filter '.codex-hook-*.tmp').Count-ne0){throw 'I24 RED resumed restore left a prepared temp'}

    Remove-Item -LiteralPath $f.Root -Recurse -Force;$f=New-Fixture;$before=[IO.File]::ReadAllBytes($f.StatePath)
    $i=Read-Result (Invoke-Entry @('-Mode','Inventory','-FixtureRoot',$f.Root,'-Json'));$repair=Read-Result (Invoke-Entry @('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration',$i.generationId,'-ApprovedMappingHash',$i.approvedMappingHash,'-Json'))
    [void](Invoke-Entry @('-Mode','Restore','-FixtureRoot',$f.Root,'-EvidencePath',$repair.evidencePath,'-Json') @{CODEX_STATE_PATH_REPAIR_FIXTURE_FAILFAST_AFTER_RESTORE_INTENT_CREATE='1'})
    $intentPath=Join-Path $repair.evidencePath 'restore-intent.json';$intent=Read-CodexRepairProtectedRecord -EvidencePath $repair.evidencePath -FileName 'restore-intent.json' -Name 'I24 out-of-bounds intent'
    $outside=Join-Path $f.Root ".codex-hook-$([guid]::NewGuid().ToString('N')).tmp";[IO.File]::WriteAllBytes($outside,$before);$outsideBefore=[IO.File]::ReadAllBytes($outside)
    $intent.payload.preparedPath=$outside;$envelope=Protect-CodexRepairAttestation $intent.payload;[IO.File]::WriteAllText($intentPath,($envelope|ConvertTo-Json -Depth 16 -Compress),[Text.UTF8Encoding]::new($false))
    $manifestPath=Join-Path $repair.evidencePath 'manifest.json';$manifestBefore=[IO.File]::ReadAllBytes($manifestPath);$targetBefore=[IO.File]::ReadAllBytes($f.StatePath)
    Assert-SingleJsonFailure (Invoke-Entry @('-Mode','Restore','-FixtureRoot',$f.Root,'-EvidencePath',$repair.evidencePath,'-Json')) 'I24 out-of-bounds prepared path'
    $manifestChanged=@(Compare-Object $manifestBefore ([IO.File]::ReadAllBytes($manifestPath))).Count-ne0;$targetChanged=@(Compare-Object $targetBefore ([IO.File]::ReadAllBytes($f.StatePath))).Count-ne0;$outsideChanged=@(Compare-Object $outsideBefore ([IO.File]::ReadAllBytes($outside))).Count-ne0
    if($manifestChanged-or$targetChanged-or$outsideChanged){throw "I24 RED out-of-bounds prepared path caused a write: manifest=$manifestChanged target=$targetChanged outside=$outsideChanged"}

    Remove-Item -LiteralPath $f.Root -Recurse -Force;$f=New-Fixture;$before=[IO.File]::ReadAllBytes($f.StatePath)
    $i=Read-Result (Invoke-Entry @('-Mode','Inventory','-FixtureRoot',$f.Root,'-Json'));$repair=Read-Result (Invoke-Entry @('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration',$i.generationId,'-ApprovedMappingHash',$i.approvedMappingHash,'-Json'))
    [void](Invoke-Entry @('-Mode','Restore','-FixtureRoot',$f.Root,'-EvidencePath',$repair.evidencePath,'-Json') @{CODEX_STATE_PATH_REPAIR_FIXTURE_FAILFAST_AFTER_RESTORE_INTENT_CREATE='1'})
    $intent=Read-CodexRepairProtectedRecord -EvidencePath $repair.evidencePath -FileName 'restore-intent.json' -Name 'I24 replaced prepared intent';$preparedPath=[string]$intent.payload.preparedPath
    $replacement=Join-Path (Split-Path -Parent $preparedPath) ".replacement-$([guid]::NewGuid().ToString('N')).tmp";[IO.File]::WriteAllBytes($replacement,$before);[IO.File]::Move($replacement,$preparedPath,$true)
    $manifestPath=Join-Path $repair.evidencePath 'manifest.json';$manifestBefore=[IO.File]::ReadAllBytes($manifestPath);$targetBefore=[IO.File]::ReadAllBytes($f.StatePath)
    Assert-SingleJsonFailure (Invoke-Entry @('-Mode','Restore','-FixtureRoot',$f.Root,'-EvidencePath',$repair.evidencePath,'-Json')) 'I24 same-bytes replacement prepared identity'
    if(@(Compare-Object $manifestBefore ([IO.File]::ReadAllBytes($manifestPath))).Count-ne0-or@(Compare-Object $targetBefore ([IO.File]::ReadAllBytes($f.StatePath))).Count-ne0){throw 'I24 RED replaced prepared identity caused a write'}
}
'I25'{
    $f=New-Fixture;$before=[IO.File]::ReadAllBytes($f.StatePath)
    $i=Read-Result (Invoke-Entry @('-Mode','Inventory','-FixtureRoot',$f.Root,'-Json'))
    [void](Invoke-Entry @('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration',$i.generationId,'-ApprovedMappingHash',$i.approvedMappingHash,'-Json') @{CODEX_STATE_PATH_REPAIR_FIXTURE_FAILFAST_AFTER_APPLY_INTENT_CREATE='1'})
    $evidence=Join-Path $f.Root "evidence\runs\$($i.generationId)"
    $cleanupCrash=Invoke-Entry @('-Mode','Restore','-FixtureRoot',$f.Root,'-EvidencePath',$evidence,'-Json') @{CODEX_STATE_PATH_REPAIR_FIXTURE_FAILFAST_AFTER_APPLY_TEMP_CLEANUP='1'}
    if($cleanupCrash.ExitCode-eq0){throw 'I25 RED cleanup pre-terminal hard-crash seam did not terminate the child'}
    if(@(Get-ChildItem -LiteralPath (Split-Path -Parent $f.StatePath) -File -Filter '.codex-hook-*.tmp').Count-ne0){throw 'I25 RED cleanup hard-crash left prepared temp'}
    $retry=Invoke-Entry @('-Mode','Restore','-FixtureRoot',$f.Root,'-EvidencePath',$evidence,'-Json');if($retry.ExitCode-ne0){throw "I25 RED already-cleaned prepared temp was not recoverable: $($retry.Text)"}
    if(@(Compare-Object $before ([IO.File]::ReadAllBytes($f.StatePath))).Count-ne0){throw 'I25 RED cleanup crash retry changed before bytes'}

    Remove-Item -LiteralPath $f.Root -Recurse -Force;$f=New-Fixture;$before=[IO.File]::ReadAllBytes($f.StatePath)
    $i=Read-Result (Invoke-Entry @('-Mode','Inventory','-FixtureRoot',$f.Root,'-Json'))
    [void](Invoke-Entry @('-Mode','Repair','-FixtureRoot',$f.Root,'-InventoryGeneration',$i.generationId,'-ApprovedMappingHash',$i.approvedMappingHash,'-Json') @{CODEX_STATE_PATH_REPAIR_FIXTURE_FAILFAST_AFTER_APPLY_INTENT_CREATE='1'})
    $evidence=Join-Path $f.Root "evidence\runs\$($i.generationId)";$intent=Read-CodexRepairProtectedRecord -EvidencePath $evidence -FileName 'apply-intent.json' -Name 'I25 third identity intent'
    Remove-Item -LiteralPath ([string]$intent.payload.preparedPath) -Force
    $replacement=Join-Path (Split-Path -Parent $f.StatePath) ".replacement-$([guid]::NewGuid().ToString('N')).tmp";[IO.File]::WriteAllBytes($replacement,$before);[IO.File]::Move($replacement,$f.StatePath,$true)
    $manifestPath=Join-Path $evidence 'manifest.json';$manifestBefore=[IO.File]::ReadAllBytes($manifestPath);$targetBefore=[IO.File]::ReadAllBytes($f.StatePath)
    Assert-SingleJsonFailure (Invoke-Entry @('-Mode','Restore','-FixtureRoot',$f.Root,'-EvidencePath',$evidence,'-Json')) 'I25 missing prepared temp with third target identity'
    if(@(Compare-Object $manifestBefore ([IO.File]::ReadAllBytes($manifestPath))).Count-ne0-or@(Compare-Object $targetBefore ([IO.File]::ReadAllBytes($f.StatePath))).Count-ne0){throw 'I25 RED missing temp plus third target identity caused a write'}
}
};"Test-CodexStatePathRepairHardening[$Case $($CaseDescriptions[$Case])]: PASS"
}finally{if($null-ne$f-and(Test-Path $f.Root)){Remove-Item $f.Root -Recurse -Force};if((Test-Path $FixtureParent)-and@(Get-ChildItem $FixtureParent -Force).Count-eq0){Remove-Item $FixtureParent -Force}}
