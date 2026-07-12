Set-StrictMode -Version Latest

function Get-CodexHookProductionFullProfile {
    [pscustomobject][ordered]@{
        profileId = 'codex-hook-production-full-v1'
        isFixtureAdapter = $false
        manifestPath = 'D:\Codex\projects\统一环境\managed\codex-hooks\manifest.json'
        sourceRoot = 'D:\Codex\projects\统一环境\managed\codex-hooks'
        codexHome = 'D:\Codex\.codex'
        hooksRoot = 'D:\Codex\.codex\hooks'
        registryPath = 'D:\Codex\.codex\hooks.json'
        planOutputDir = 'D:\Codex\projects\统一环境\reports\codex-hook-deployment-plan'
        planPath = 'D:\Codex\projects\统一环境\reports\codex-hook-deployment-plan\plan.json'
        evidenceRoot = 'D:\Codex\.codex\run-evidence\env-governance'
        mutexName = 'Local\CodexHookProductionFullV1'
    }
}

function Get-CodexHookProductionFullFixtureProfile {
    $root = 'D:\Codex\projects\统一环境\reports\codex-hook-deployment-test\production-full'
    [pscustomobject][ordered]@{
        profileId = 'codex-hook-production-full-v1'
        isFixtureAdapter = $true
        manifestPath = Join-Path $root 'source\manifest.json'
        sourceRoot = Join-Path $root 'source'
        codexHome = Join-Path $root 'live'
        hooksRoot = Join-Path $root 'live\hooks'
        registryPath = Join-Path $root 'live\hooks.json'
        planOutputDir = Join-Path $root 'plan'
        planPath = Join-Path $root 'plan\plan.json'
        evidenceRoot = Join-Path $root 'evidence'
        mutexName = 'Local\CodexHookProductionFullFixtureV1'
    }
}

function Assert-CodexHookProductionFullProfile {
    param([Parameter(Mandatory)][object]$Profile, [switch]$AllowFixtureAdapter)
    Assert-CodexHookExactProperties -Value $Profile -Names @(
        'profileId','isFixtureAdapter','manifestPath','sourceRoot','codexHome','hooksRoot',
        'registryPath','planOutputDir','planPath','evidenceRoot','mutexName'
    ) -Scope 'production full profile'
    if ($Profile.profileId -cne 'codex-hook-production-full-v1') { throw 'production full profileId 非法。' }
    if ($Profile.isFixtureAdapter -and -not $AllowFixtureAdapter) { throw 'production full fixture adapter 未授权。' }
    foreach ($name in @('manifestPath','sourceRoot','codexHome','hooksRoot','registryPath','planOutputDir','planPath','evidenceRoot')) {
        [void](Assert-CodexHookDPath -Value ([string]$Profile.$name) -Name "production full $name")
    }
    if ([IO.Path]::GetFullPath([string]$Profile.hooksRoot) -ine [IO.Path]::GetFullPath((Join-Path ([string]$Profile.codexHome) 'hooks'))) { throw 'production full hooksRoot 映射非法。' }
    if ([IO.Path]::GetFullPath([string]$Profile.registryPath) -ine [IO.Path]::GetFullPath((Join-Path ([string]$Profile.codexHome) 'hooks.json'))) { throw 'production full registryPath 映射非法。' }
    if ([IO.Path]::GetFullPath([string]$Profile.planPath) -ine [IO.Path]::GetFullPath((Join-Path ([string]$Profile.planOutputDir) 'plan.json'))) { throw 'production full planPath 映射非法。' }
    if (-not $Profile.isFixtureAdapter) {
        $expected = Get-CodexHookProductionFullProfile
        foreach ($name in $expected.PSObject.Properties.Name) {
            if ($Profile.$name -cne $expected.$name) { throw "production full fixed profile 漂移：$name" }
        }
    } else {
        $fixtureRoot = 'D:\Codex\projects\统一环境\reports\codex-hook-deployment-test\production-full'
        foreach ($name in @('manifestPath','sourceRoot','codexHome','hooksRoot','registryPath','planOutputDir','planPath','evidenceRoot')) {
            if (-not (Test-CodexHookPathWithin -Path ([string]$Profile.$name) -ParentPath $fixtureRoot)) { throw "production full fixture path 越界：$name" }
        }
        if ($Profile.mutexName -cne 'Local\CodexHookProductionFullFixtureV1') { throw 'production full fixture mutex 非法。' }
    }
    return $true
}

function Get-CodexHookProductionFullMappingIdentity {
    param([Parameter(Mandatory)][object]$Profile)
    $parts = @('codex-hook-production-full-v1') + @($Profile.manifestPath,$Profile.sourceRoot,$Profile.codexHome,$Profile.registryPath,$Profile.evidenceRoot) |
        ForEach-Object { if ($_ -ceq 'codex-hook-production-full-v1') { $_ } else { ([IO.Path]::GetFullPath([string]$_)).ToLowerInvariant() } }
    return Get-CodexHookTextSha256 -Text ($parts -join "`0")
}

function Get-CodexHookProductionFullEnvironmentFact {
    param([Parameter(Mandatory)][scriptblock]$EnvironmentReadValue)
    return Get-CodexHookEnvironmentValueFact -Name 'SERENA_HOME' -Scope 'User' -ReadValue $EnvironmentReadValue -Desired 'D:\Codex\.serena'
}

function Get-CodexHookProductionFullUnknownLiveProjection {
    param([Parameter(Mandatory)][object]$Profile,[Parameter(Mandatory)][object]$Manifest)
    $known=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($file in @($Manifest.files)){[void]$known.Add(([string]$file.liveRelativePath -replace '\\','/'))}
    $facts=[Collections.Generic.List[string]]::new()
    if([IO.Directory]::Exists([string]$Profile.hooksRoot)){
        foreach($item in @(Get-ChildItem -LiteralPath ([string]$Profile.hooksRoot) -File -Recurse -Force | Sort-Object FullName)){
            $relative=[IO.Path]::GetRelativePath([string]$Profile.hooksRoot,$item.FullName).Replace('\','/')
            if($known.Contains($relative)){continue}
            $snapshot=Get-CodexHookCapabilityFileSnapshot $item.FullName ([string]$Profile.hooksRoot) @($item.FullName) 'production full unknown live projection'
            $facts.Add("$relative`0$($snapshot.sha256)")
        }
    }
    $projectionText=if($facts.Count){$facts -join "`n"}else{'<empty>'}
    return [pscustomobject][ordered]@{count=$facts.Count;sha256=Get-CodexHookTextSha256 -Text $projectionText}
}

function Assert-CodexHookProductionFullPlan {
    param([Parameter(Mandatory)][object]$Plan,[Parameter(Mandatory)][object]$Profile)
    Assert-CodexHookExactProperties -Value $Plan -Names @(
        'artifactType','schemaVersion','generationId','generatedAtUtc','manifestSha256','mode','applyEligible',
        'sourceFacts','liveFacts','registryBeforeSha256','registryAfterSha256','actions','environmentActions',
        'postChecks','rollbackRequired','projectionSummary'
    ) -Scope 'production full plan'
    foreach($name in @('artifactType','generationId','generatedAtUtc','manifestSha256','mode','registryBeforeSha256','registryAfterSha256')) { Assert-CodexHookString -Value $Plan.$name -Name "production full plan $name" }
    Assert-CodexHookInteger -Value $Plan.schemaVersion -Name 'production full schemaVersion'
    if($Plan.artifactType -cne 'env-governance.codex-hook-deployment-plan' -or [int]$Plan.schemaVersion -ne 1){throw 'production full plan artifact/schema 非法。'}
    [void](Assert-CodexHookGenerationId -Value ([string]$Plan.generationId))
    $generated=[datetimeoffset]::MinValue
    if(-not [datetimeoffset]::TryParse([string]$Plan.generatedAtUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$generated)-or $generated -gt [datetimeoffset]::UtcNow.AddMinutes(5)-or $generated -lt [datetimeoffset]::UtcNow.AddHours(-1)){throw 'production full plan 已过期或时间非法。'}
    foreach($hashName in @('manifestSha256','registryBeforeSha256','registryAfterSha256')){if([string]$Plan.$hashName -cnotmatch '^[0-9a-f]{64}$'){throw "production full $hashName 非法。"}}
    if($Plan.rollbackRequired -isnot [bool] -or -not $Plan.rollbackRequired){throw 'production full plan 必须声明 rollbackRequired。'}
    foreach($arrayName in @('actions','environmentActions','postChecks')){Assert-CodexHookArray -Value ([object]$Plan.$arrayName) -Name "production full $arrayName"}
    Assert-CodexHookExactProperties -Value $Plan.sourceFacts -Names @('targetProfile','mappingIdentity','manifestPath','manifestSha256','sourceRoot','files','blockerReasonCodes') -Scope 'production full sourceFacts'
    Assert-CodexHookExactProperties -Value $Plan.liveFacts -Names @('targetProfile','mappingIdentity','codexHome','hooksRoot','registryPath','files','blockerReasonCodes') -Scope 'production full liveFacts'
    if(@($Plan.sourceFacts.blockerReasonCodes).Count -or @($Plan.liveFacts.blockerReasonCodes).Count){throw 'production full applyEligible plan 不得包含 blocker。'}
    if($Profile.isFixtureAdapter){
        $basePlan = ($Plan | ConvertTo-Json -Depth 100) | ConvertFrom-Json -Depth 100 -DateKind String
        $basePlan.PSObject.Properties.Remove('projectionSummary')
        $basePlan.sourceFacts.targetProfile='codex-hook-fixture-v1';$basePlan.liveFacts.targetProfile='codex-hook-fixture-v1'
        [void](Assert-CodexHookDeploymentPlanFresh -Plan $basePlan)
    } else {
        foreach($fact in @($Plan.sourceFacts.files)){Assert-CodexHookExactProperties $fact @('relativePath','path','exists','probeState','sha256') 'production full source fact';[void](Assert-CodexHookRelativePath $fact.relativePath);if(-not(Test-CodexHookPathWithin ([string]$fact.path) ([string]$Profile.sourceRoot))){throw 'production full source fact 越界。'}}
        foreach($fact in @($Plan.liveFacts.files)){Assert-CodexHookExactProperties $fact @('liveRelativePath','path','exists','probeState','sha256') 'production full live fact';[void](Assert-CodexHookRelativePath $fact.liveRelativePath);if(-not(Test-CodexHookPathWithin ([string]$fact.path) ([string]$Profile.hooksRoot))){throw 'production full live fact 越界。'}}
        foreach($action in @($Plan.actions)){Assert-CodexHookExactProperties $action @('actionId','phase','kind','sourceRef','sourceSha256','logicalTarget','targetPath','beforeExists','beforeSha256','afterSha256','restoreOrder') 'production full action';if($action.kind -ceq 'registry'){if($action.targetPath -cne $Profile.registryPath -or $action.phase -cne 'registry'){throw 'production full registry action 非法。'}}elseif($action.kind -ceq 'file'){if(-not(Test-CodexHookPathWithin ([string]$action.targetPath) ([string]$Profile.hooksRoot))){throw 'production full file action 越界。'}}else{throw 'production full action kind 非法。'}}
        foreach($action in @($Plan.environmentActions)){Assert-CodexHookExactProperties $action @('actionId','phase','kind','name','scope','after','beforePresent','beforeMatchesTarget','beforeValueSha256','afterValueSha256','restoreOrder') 'production full environment action';if($action.name -cne 'SERENA_HOME' -or $action.scope -cne 'User' -or $action.after -cne 'D:\Codex\.serena'){throw 'production full environment action 非法。'}}
    }
    Assert-CodexHookExactProperties -Value $Plan.projectionSummary -Names @('restartRequired','fileActions','environmentActions','unknownLiveCount','unknownLiveSha256') -Scope 'production full projection summary'
    Assert-CodexHookInteger -Value $Plan.projectionSummary.unknownLiveCount -Name 'production full unknownLiveCount'
    if (
        $Plan.mode -cne 'full' -or $Plan.applyEligible -isnot [bool] -or -not $Plan.applyEligible -or
        $Plan.sourceFacts.targetProfile -cne 'codex-hook-production-full-v1' -or
        $Plan.liveFacts.targetProfile -cne 'codex-hook-production-full-v1' -or
        $Plan.sourceFacts.mappingIdentity -cne (Get-CodexHookProductionFullMappingIdentity -Profile $Profile) -or
        $Plan.liveFacts.mappingIdentity -cne (Get-CodexHookProductionFullMappingIdentity -Profile $Profile) -or
        $Plan.projectionSummary.restartRequired -ne $true -or
        [string]$Plan.projectionSummary.unknownLiveSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        [int]$Plan.projectionSummary.fileActions -ne @($Plan.actions | Where-Object kind -ceq 'file').Count -or
        [int]$Plan.projectionSummary.environmentActions -ne @($Plan.environmentActions).Count
    ) { throw 'production full plan profile/applyEligible/projection contract 非法。' }
    return $true
}

function New-CodexHookProductionFullState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Profile, [Parameter(Mandatory)][scriptblock]$EnvironmentReadValue)
    [void](Assert-CodexHookProductionFullProfile -Profile $Profile -AllowFixtureAdapter)
    $manifestSnapshot = Get-CodexHookCapabilityFileSnapshot -Path ([string]$Profile.manifestPath) -CapabilityRoot ([string]$Profile.sourceRoot) -AllowedExactPaths @([string]$Profile.manifestPath) -Name 'production full manifest'
    Assert-CodexHookStrictJsonText -JsonText ([Text.UTF8Encoding]::new($false,$true).GetString([byte[]]$manifestSnapshot.bytes))
    $manifest = ([Text.UTF8Encoding]::new($false,$true).GetString([byte[]]$manifestSnapshot.bytes)) | ConvertFrom-Json -Depth 128
    [void](Assert-CodexHookManifest -Manifest $manifest)
    if (@($manifest.environment).Count -ne 1 -or $manifest.environment[0].name -cne 'SERENA_HOME' -or $manifest.environment[0].scope -cne 'User' -or $manifest.environment[0].desired -cne 'D:\Codex\.serena') { throw 'production full environment manifest 必须是唯一 User SERENA_HOME。' }
    $sourceFacts = [Collections.Generic.List[object]]::new(); $liveFacts = [Collections.Generic.List[object]]::new(); $sourceBytes = @{}
    foreach ($file in @($manifest.files)) {
        $sourcePath = [IO.Path]::GetFullPath((Join-Path ([string]$Profile.sourceRoot) ([string]$file.relativePath)))
        $livePath = [IO.Path]::GetFullPath((Join-Path ([string]$Profile.hooksRoot) ([string]$file.liveRelativePath)))
        if (-not (Test-CodexHookPathWithin $sourcePath ([string]$Profile.sourceRoot)) -or -not (Test-CodexHookPathWithin $livePath ([string]$Profile.hooksRoot))) { throw 'production full file mapping 越界。' }
        $source = Get-CodexHookCapabilityFileSnapshot -Path $sourcePath -CapabilityRoot ([string]$Profile.sourceRoot) -AllowedExactPaths @($sourcePath) -Name 'production full source'
        $live = Get-CodexHookCapabilityFileSnapshot -Path $livePath -CapabilityRoot ([string]$Profile.hooksRoot) -AllowedExactPaths @($livePath) -Name 'production full live'
        $sourceFacts.Add([pscustomobject][ordered]@{ relativePath=[string]$file.relativePath; path=$sourcePath; exists=[bool]$source.exists; probeState=[string]$source.state; sha256=[string]$source.sha256 })
        $liveFacts.Add([pscustomobject][ordered]@{ liveRelativePath=[string]$file.liveRelativePath; path=$livePath; exists=[bool]$live.exists; probeState=[string]$live.state; sha256=[string]$live.sha256 })
        if ($source.exists) { $sourceBytes[[string]$file.relativePath] = [byte[]]$source.bytes }
    }
    $registrySnapshot = Get-CodexHookCapabilityFileSnapshot -Path ([string]$Profile.registryPath) -CapabilityRoot ([string]$Profile.codexHome) -AllowedExactPaths @([string]$Profile.registryPath) -Name 'production full registry'
    $registryText = [Text.UTF8Encoding]::new($false,$true).GetString([byte[]]$registrySnapshot.bytes)
    Assert-CodexHookStrictJsonText -JsonText $registryText
    $registry = $registryText | ConvertFrom-Json -Depth 128
    $desiredRegistry = Merge-CodexHookRegistry -Manifest $manifest -LiveRegistry $registry -Mode full
    $envFact = Get-CodexHookProductionFullEnvironmentFact -EnvironmentReadValue $EnvironmentReadValue
    $inventory = [pscustomobject][ordered]@{
        targetProfile='codex-hook-fixture-v1'; mappingIdentity=(Get-CodexHookFixtureMappingIdentity -Manifest $manifest -SourceRoot ([string]$Profile.sourceRoot) -CodexHome ([string]$Profile.codexHome));
        manifestPath=[string]$Profile.manifestPath; manifestSha256=[string]$manifestSnapshot.sha256; sourceRoot=[string]$Profile.sourceRoot; codexHome=[string]$Profile.codexHome;
        hooksRoot=[string]$Profile.hooksRoot; registryPath=[string]$Profile.registryPath; registryBeforeSha256=[string]$registrySnapshot.sha256;
        sourceFiles=[object[]]$sourceFacts.ToArray(); liveFiles=[object[]]$liveFacts.ToArray(); environmentFacts=@($envFact); blockers=@()
    }
    $plan = New-CodexHookDeploymentPlanDocument -Manifest $manifest -Inventory $inventory -DesiredRegistry $desiredRegistry -Mode full
    $plan.sourceFacts.targetProfile = 'codex-hook-production-full-v1'; $plan.liveFacts.targetProfile = 'codex-hook-production-full-v1'
    $identity = Get-CodexHookProductionFullMappingIdentity -Profile $Profile
    $plan.sourceFacts.mappingIdentity = $identity; $plan.liveFacts.mappingIdentity = $identity
    $unknownLive=Get-CodexHookProductionFullUnknownLiveProjection -Profile $Profile -Manifest $manifest
    $plan | Add-Member -NotePropertyName projectionSummary -NotePropertyValue ([pscustomobject][ordered]@{
        restartRequired=$true; fileActions=@($plan.actions | Where-Object kind -ceq 'file').Count; environmentActions=@($plan.environmentActions).Count; unknownLiveCount=[int]$unknownLive.count; unknownLiveSha256=[string]$unknownLive.sha256
    })
    return [pscustomobject][ordered]@{ plan=$plan; manifest=$manifest; manifestSnapshot=$manifestSnapshot; registry=$registry; registrySnapshot=$registrySnapshot; desiredRegistry=$desiredRegistry; desiredRegistryBytes=(ConvertTo-CodexHookRegistryBytes $desiredRegistry); sourceBytes=$sourceBytes; environmentFact=$envFact }
}

function Get-CodexHookProductionFullLifecyclePaths {
    param([Parameter(Mandatory)][object]$Profile,[Parameter(Mandatory)][string]$GenerationId)
    [void](Assert-CodexHookGenerationId $GenerationId)
    $evidence = Join-Path ([string]$Profile.evidenceRoot) "deployment-$GenerationId"
    [pscustomobject][ordered]@{ claimsRoot=Join-Path ([string]$Profile.evidenceRoot) '.claims'; claimPath=Join-Path ([string]$Profile.evidenceRoot) ".claims\$GenerationId.json"; activePath=Join-Path ([string]$Profile.evidenceRoot) '.production-full-active.json'; evidenceDirectory=$evidence; backupsRoot=Join-Path $evidence 'backups'; restoreManifestPath=Join-Path $evidence 'restore-manifest.json'; attestationPath=Join-Path $evidence 'attestation.json'; statusPath=Join-Path $evidence 'status.json' }
}

function Set-CodexHookProductionFullJson {
    param([string]$Path,[object]$Document,[object]$Profile,[string]$Scope='production full evidence')
    Set-CodexHookCapabilityJson -Path $Path -Document $Document -CapabilityRoot ([string]$Profile.evidenceRoot) -AllowedExactPaths @($Path) -Scope $Scope
}

function Invoke-CodexHookProductionFullEnvironmentWrite {
    param([scriptblock]$Writer,[AllowNull()][string]$Value)
    & $Writer 'SERENA_HOME' 'User' $Value
}

function Protect-CodexHookProductionFullEnvironmentBackup {
    param([Parameter(Mandatory)][object]$Value)
    [byte[]]$plain=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 10 -Compress))
    [byte[]]$entropy=[Text.UTF8Encoding]::new($false).GetBytes('codex-hook-production-full-v1/environment-backup')
    [byte[]]$cipher=[Security.Cryptography.ProtectedData]::Protect($plain,$entropy,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [pscustomobject][ordered]@{protection='dpapi-current-user-v1';data=[Convert]::ToBase64String($cipher)}
}

function Unprotect-CodexHookProductionFullEnvironmentBackup {
    param([Parameter(Mandatory)][object]$Document)
    Assert-CodexHookExactProperties $Document @('protection','data') 'production full protected environment backup'
    if($Document.protection -cne 'dpapi-current-user-v1' -or $Document.data -isnot [string]){throw 'production full environment backup protection 非法。'}
    [byte[]]$entropy=[Text.UTF8Encoding]::new($false).GetBytes('codex-hook-production-full-v1/environment-backup')
    [byte[]]$plain=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String([string]$Document.data),$entropy,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    $value=[Text.UTF8Encoding]::new($false,$true).GetString($plain)|ConvertFrom-Json -Depth 10
    Assert-CodexHookExactProperties $value @('present','value') 'production full environment backup value'
    if($value.present -isnot [bool]){throw 'production full environment backup present 非法。'}
    return $value
}

function Protect-CodexHookProductionFullAttestation {
    param([Parameter(Mandatory)][object]$Payload)
    [byte[]]$plain=[Text.UTF8Encoding]::new($false).GetBytes(($Payload|ConvertTo-Json -Depth 20 -Compress))
    [byte[]]$entropy=[Text.UTF8Encoding]::new($false).GetBytes('codex-hook-production-full-v1/evidence-attestation')
    [byte[]]$cipher=[Security.Cryptography.ProtectedData]::Protect($plain,$entropy,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [pscustomobject][ordered]@{protection='dpapi-current-user-v1';trustBoundary='same-windows-user';data=[Convert]::ToBase64String($cipher)}
}

function Unprotect-CodexHookProductionFullAttestation {
    param([Parameter(Mandatory)][object]$Document)
    Assert-CodexHookExactProperties $Document @('protection','trustBoundary','data') 'production full evidence attestation envelope'
    if($Document.protection -cne 'dpapi-current-user-v1' -or $Document.trustBoundary -cne 'same-windows-user' -or $Document.data -isnot [string]){throw 'production full evidence attestation envelope 非法。'}
    [byte[]]$entropy=[Text.UTF8Encoding]::new($false).GetBytes('codex-hook-production-full-v1/evidence-attestation')
    try{[byte[]]$plain=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String([string]$Document.data),$entropy,[Security.Cryptography.DataProtectionScope]::CurrentUser)}catch{throw 'production full evidence attestation 认证失败；同一 Windows user 是授权信任边界。'}
    return ([Text.UTF8Encoding]::new($false,$true).GetString($plain))|ConvertFrom-Json -Depth 20
}

function Enter-CodexHookProductionFullMutex {
    param([Parameter(Mandatory)][string]$Name)
    $mutex=[Threading.Mutex]::new($false,$Name);$held=$false
    try {
        try { $held=$mutex.WaitOne(1500) } catch [Threading.AbandonedMutexException] { $held=$true }
        if(-not $held){throw 'production full mutex busy。'}
        return [pscustomobject]@{mutex=$mutex;held=$true}
    } catch {
        if(-not $held){$mutex.Dispose()}
        throw
    }
}

function Exit-CodexHookProductionFullMutex {
    param([Parameter(Mandatory)][object]$Lease)
    try{if($Lease.held){[void]$Lease.mutex.ReleaseMutex();$Lease.held=$false}}finally{$Lease.mutex.Dispose()}
}

function New-CodexHookProductionFullActiveDocument {
    param(
        [Parameter(Mandatory)][object]$Profile,
        [Parameter(Mandatory)][string]$GenerationId,
        [Parameter(Mandatory)][string]$EvidenceDirectory,
        [Parameter(Mandatory)][ValidateSet('applying','applied','restored','rolled-back')][string]$State,
        [AllowNull()][object]$PreviousActive
    )
    [void](Assert-CodexHookGenerationId $GenerationId)
    if($null -ne $PreviousActive){
        Assert-CodexHookExactProperties $PreviousActive @('artifactType','schemaVersion','profileId','generationId','evidenceDirectory','state','previousGenerationId','previousEvidenceDirectory') 'production full previous active pointer'
        $expectedPreviousEvidence=(Get-CodexHookProductionFullLifecyclePaths -Profile $Profile -GenerationId ([string]$PreviousActive.generationId)).evidenceDirectory
        if(
            $PreviousActive.artifactType -cne 'env-governance.codex-hook-production-full-active' -or
            [int]$PreviousActive.schemaVersion -ne 1 -or
            $PreviousActive.profileId -cne $Profile.profileId -or
            $PreviousActive.generationId -ceq $GenerationId -or
            $PreviousActive.evidenceDirectory -cne $expectedPreviousEvidence -or
            $PreviousActive.evidenceDirectory -ceq $EvidenceDirectory -or
            $PreviousActive.previousGenerationId -ceq $GenerationId -or
            $PreviousActive.previousEvidenceDirectory -ceq $EvidenceDirectory -or
            $PreviousActive.state -ceq 'applying' -or
            (($null -eq $PreviousActive.previousGenerationId) -ne ($null -eq $PreviousActive.previousEvidenceDirectory))
        ){throw 'production full active lineage schema/cycle/unsettled predecessor。'}
    }
    return [pscustomobject][ordered]@{
        artifactType='env-governance.codex-hook-production-full-active'
        schemaVersion=1
        profileId=[string]$Profile.profileId
        generationId=$GenerationId
        evidenceDirectory=$EvidenceDirectory
        state=$State
        previousGenerationId=if($null -ne $PreviousActive){[string]$PreviousActive.generationId}else{$null}
        previousEvidenceDirectory=if($null -ne $PreviousActive){[string]$PreviousActive.evidenceDirectory}else{$null}
    }
}

function Invoke-CodexHookProductionFullApplyEngine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Profile,[Parameter(Mandatory)][scriptblock]$EnvironmentReadValue,[Parameter(Mandatory)][scriptblock]$EnvironmentWriteValue,[ValidateSet('none','before-registry')][string]$TestFaultInjection='none')
    [void](Assert-CodexHookProductionFullProfile -Profile $Profile -AllowFixtureAdapter)
    if ($TestFaultInjection -cne 'none' -and -not $Profile.isFixtureAdapter) { throw 'production full fault seam 仅允许 fixture adapter。' }
    $planSnapshot = Get-CodexHookCapabilityFileSnapshot -Path ([string]$Profile.planPath) -CapabilityRoot ([string]$Profile.planOutputDir) -AllowedExactPaths @([string]$Profile.planPath) -Name 'production full plan'
    $planText=[Text.UTF8Encoding]::new($false,$true).GetString([byte[]]$planSnapshot.bytes); Assert-CodexHookStrictJsonText $planText; $plan=$planText|ConvertFrom-Json -Depth 128 -DateKind String
    [void](Assert-CodexHookProductionFullPlan -Plan $plan -Profile $Profile)
    $paths=Get-CodexHookProductionFullLifecyclePaths $Profile ([string]$plan.generationId)
    if (Test-Path -LiteralPath ([string]$paths.claimPath)) { throw 'production full generation 已被永久 claim；拒绝重放。' }
    $state=New-CodexHookProductionFullState -Profile $Profile -EnvironmentReadValue $EnvironmentReadValue
    foreach($name in @('manifestSha256','applyEligible','sourceFacts','liveFacts','registryBeforeSha256','registryAfterSha256','actions','environmentActions','postChecks','rollbackRequired','projectionSummary')) { if (($plan.$name|ConvertTo-Json -Depth 100 -Compress)-cne($state.plan.$name|ConvertTo-Json -Depth 100 -Compress)){throw "production full fresh rederive 失败：$name"} }
    $lease=$null
    try {
        $lease=Enter-CodexHookProductionFullMutex -Name ([string]$Profile.mutexName)
        if(Test-Path -LiteralPath ([string]$paths.claimPath)){throw 'production full generation 已被永久 claim；拒绝重放。'}
        $existingActiveSnapshot=Get-CodexHookCapabilityFileSnapshot ([string]$paths.activePath) ([string]$Profile.evidenceRoot) @([string]$paths.activePath) 'production full existing active generation'
        if($existingActiveSnapshot.exists){$existingActive=([Text.UTF8Encoding]::new($false,$true).GetString([byte[]]$existingActiveSnapshot.bytes))|ConvertFrom-Json -Depth 32;Assert-CodexHookExactProperties $existingActive @('artifactType','schemaVersion','profileId','generationId','evidenceDirectory','state','previousGenerationId','previousEvidenceDirectory') 'production full existing active generation';if($existingActive.state -ceq 'applying'){throw "production full recovery-required：$($existingActive.evidenceDirectory)"}}
        $state=New-CodexHookProductionFullState -Profile $Profile -EnvironmentReadValue $EnvironmentReadValue
        foreach($name in @('manifestSha256','applyEligible','sourceFacts','liveFacts','registryBeforeSha256','registryAfterSha256','actions','environmentActions','postChecks','rollbackRequired','projectionSummary')) { if (($plan.$name|ConvertTo-Json -Depth 100 -Compress)-cne($state.plan.$name|ConvertTo-Json -Depth 100 -Compress)){throw "production full critical rederive 失败：$name"} }
        $allActions=@(@($plan.actions)+@($plan.environmentActions)|Sort-Object restoreOrder)
        $allNoOp=@($plan.actions|Where-Object {$_.kind -ne 'registry' -and $_.beforeSha256 -cne $_.afterSha256}).Count -eq 0 -and $plan.registryBeforeSha256 -ceq $plan.registryAfterSha256 -and $state.environmentFact.matchesTarget
        if($allNoOp){return [pscustomobject][ordered]@{applied=$false;noOp=$true;refusalReason='already-converged';generationId=[string]$plan.generationId}}
        [void](New-CodexHookCapabilityDirectory ([string]$paths.claimsRoot) ([string]$Profile.evidenceRoot));[void](New-CodexHookCapabilityDirectory ([string]$paths.evidenceDirectory) ([string]$Profile.evidenceRoot) -RequireMissing);[void](New-CodexHookCapabilityDirectory ([string]$paths.backupsRoot) ([string]$Profile.evidenceRoot) -RequireMissing)
        $restoreActions=[Collections.Generic.List[object]]::new()
        $manifestBackupRelativePath='backups\manifest.json';$manifestBackupPath=Join-Path ([string]$paths.evidenceDirectory) $manifestBackupRelativePath
        Set-CodexHookAtomicFileBytesWithCapability $manifestBackupPath ([byte[]]$state.manifestSnapshot.bytes) $false $null ([string]$state.manifestSnapshot.sha256) ([string]$Profile.evidenceRoot) @($manifestBackupPath) 'production full manifest backup'
        $previousActiveBackupRelativePath=$null
        $previousActiveBackupSha256=$null
        if($existingActiveSnapshot.exists){
            $previousActiveBackupRelativePath='backups\previous-active.json'
            $previousActiveBackupPath=Join-Path ([string]$paths.evidenceDirectory) $previousActiveBackupRelativePath
            Set-CodexHookAtomicFileBytesWithCapability $previousActiveBackupPath ([byte[]]$existingActiveSnapshot.bytes) $false $null ([string]$existingActiveSnapshot.sha256) ([string]$Profile.evidenceRoot) @($previousActiveBackupPath) 'production full previous active backup'
            $previousActiveBackupSha256=[string]$existingActiveSnapshot.sha256
        }
        foreach($action in $allActions){
            if($action.kind -ceq 'environment'){
                $backupValue=[pscustomobject][ordered]@{present=[bool]$state.environmentFact.present;value=if($state.environmentFact.present){[string]$state.environmentFact.value}else{$null}}
                $backup=Protect-CodexHookProductionFullEnvironmentBackup -Value $backupValue
                $rel="backups\$('{0:d3}' -f [int]$action.restoreOrder)-environment.json";$bp=Join-Path ([string]$paths.evidenceDirectory) $rel;Set-CodexHookProductionFullJson $bp $backup $Profile
                $bs=Get-CodexHookCapabilityFileSnapshot $bp ([string]$Profile.evidenceRoot) @($bp) 'production full environment backup'
                $restoreActions.Add([pscustomobject][ordered]@{actionId=[string]$action.actionId;kind='environment';path=$null;beforeExists=$null;beforeSha256=$null;backupRelativePath=$rel;backupSha256=[string]$bs.sha256;deployedSha256=[string]$action.afterValueSha256;restoreOrder=[int]$action.restoreOrder})
            } else {
                $target=[string]$action.targetPath;$snap=Get-CodexHookCapabilityFileSnapshot $target ([string]$Profile.codexHome) @($target) 'production full backup source';$rel=$null;$sha=$null
                if($snap.exists){$rel="backups\$('{0:d3}' -f [int]$action.restoreOrder).bin";$bp=Join-Path ([string]$paths.evidenceDirectory) $rel;Set-CodexHookAtomicFileBytesWithCapability $bp ([byte[]]$snap.bytes) $false $null ([string]$snap.sha256) ([string]$Profile.evidenceRoot) @($bp) 'production full backup';$sha=[string]$snap.sha256}
                $restoreActions.Add([pscustomobject][ordered]@{actionId=[string]$action.actionId;kind=[string]$action.kind;path=$target;beforeExists=[bool]$snap.exists;beforeSha256=[string]$snap.sha256;backupRelativePath=$rel;backupSha256=$sha;deployedSha256=[string]$action.afterSha256;restoreOrder=[int]$action.restoreOrder})
            }
        }
        $restore=[pscustomobject][ordered]@{artifactType='env-governance.codex-hook-production-full-restore';schemaVersion=1;profileId=[string]$Profile.profileId;generationId=[string]$plan.generationId;planSha256=[string]$planSnapshot.sha256;mappingIdentity=[string]$plan.sourceFacts.mappingIdentity;manifestBackupRelativePath=$manifestBackupRelativePath;manifestBackupSha256=[string]$state.manifestSnapshot.sha256;previousActiveBackupRelativePath=$previousActiveBackupRelativePath;previousActiveBackupSha256=$previousActiveBackupSha256;actions=[object[]]$restoreActions.ToArray()}
        Set-CodexHookProductionFullJson ([string]$paths.restoreManifestPath) $restore $Profile;$rs=Get-CodexHookCapabilityFileSnapshot ([string]$paths.restoreManifestPath) ([string]$Profile.evidenceRoot) @([string]$paths.restoreManifestPath) 'production full restore manifest'
        $attestationPayload=[pscustomobject][ordered]@{artifactType='env-governance.codex-hook-production-full-attestation';schemaVersion=1;profileId=[string]$Profile.profileId;claimState='prepared';generationId=[string]$plan.generationId;mappingIdentity=[string]$plan.sourceFacts.mappingIdentity;planSha256=[string]$planSnapshot.sha256;evidenceDirectory=[string]$paths.evidenceDirectory;restoreManifestSha256=[string]$rs.sha256;manifestBackupSha256=[string]$state.manifestSnapshot.sha256;previousActiveBackupSha256=$previousActiveBackupSha256}
        $attestation=Protect-CodexHookProductionFullAttestation -Payload $attestationPayload
        Set-CodexHookProductionFullJson ([string]$paths.attestationPath) $attestation $Profile
        $attestationSnapshot=Get-CodexHookCapabilityFileSnapshot ([string]$paths.attestationPath) ([string]$Profile.evidenceRoot) @([string]$paths.attestationPath) 'production full attestation'
        $claim=[pscustomobject][ordered]@{artifactType='env-governance.codex-hook-deployment-claim';schemaVersion=1;profileId=[string]$Profile.profileId;state='prepared';generationId=[string]$plan.generationId;mappingIdentity=[string]$plan.sourceFacts.mappingIdentity;planSha256=[string]$planSnapshot.sha256;evidenceDirectory=[string]$paths.evidenceDirectory;restoreManifestSha256=[string]$rs.sha256;attestationSha256=[string]$attestationSnapshot.sha256};Set-CodexHookProductionFullJson ([string]$paths.claimPath) $claim $Profile
        $status=[pscustomobject][ordered]@{
            artifactType='env-governance.codex-hook-production-full-status'
            schemaVersion=1
            profileId=[string]$Profile.profileId
            generationId=[string]$plan.generationId
            status='applying'
            completedActionIds=@()
            restoredActionIds=@()
        }
        Set-CodexHookProductionFullJson ([string]$paths.statusPath) $status $Profile
        $previousActive=$null
        $activeBefore=Get-CodexHookCapabilityFileSnapshot ([string]$paths.activePath) ([string]$Profile.evidenceRoot) @([string]$paths.activePath) 'production full previous active generation'
        if($activeBefore.exists){$previousActive=([Text.UTF8Encoding]::new($false,$true).GetString([byte[]]$activeBefore.bytes))|ConvertFrom-Json -Depth 32;Assert-CodexHookExactProperties $previousActive @('artifactType','schemaVersion','profileId','generationId','evidenceDirectory','state','previousGenerationId','previousEvidenceDirectory') 'production full previous active generation';if($previousActive.artifactType -cne 'env-governance.codex-hook-production-full-active' -or [int]$previousActive.schemaVersion -ne 1 -or $previousActive.profileId -cne $Profile.profileId -or $previousActive.state -ceq 'applying'){throw 'production full previous active generation 未收敛。'}}
        $active=New-CodexHookProductionFullActiveDocument -Profile $Profile -GenerationId ([string]$plan.generationId) -EvidenceDirectory ([string]$paths.evidenceDirectory) -State applying -PreviousActive $previousActive
        Set-CodexHookProductionFullJson ([string]$paths.activePath) $active $Profile
        $completed=[Collections.Generic.List[string]]::new()
        try {
            foreach($action in $allActions){
                if($TestFaultInjection -ceq 'before-registry' -and $action.kind -ceq 'registry'){throw 'test-fault:before-registry'}
                if($action.kind -ceq 'file'){$bytes=[byte[]]$state.sourceBytes[[string]$action.sourceRef];Set-CodexHookAtomicFileBytesWithCapability ([string]$action.targetPath) $bytes ([bool]$action.beforeExists) ([string]$action.beforeSha256) ([string]$action.afterSha256) ([string]$Profile.hooksRoot) @([string]$action.targetPath) 'production full file publish'}
                elseif($action.kind -ceq 'environment'){ $current=Get-CodexHookProductionFullEnvironmentFact $EnvironmentReadValue;if($current.valueSha256 -cne $action.beforeValueSha256){throw 'production full environment 漂移。'};Invoke-CodexHookProductionFullEnvironmentWrite $EnvironmentWriteValue ([string]$action.after);$after=Get-CodexHookProductionFullEnvironmentFact $EnvironmentReadValue;if($after.valueSha256 -cne $action.afterValueSha256){throw 'production full environment postcheck 失败。'} }
                elseif($action.kind -ceq 'registry'){Set-CodexHookAtomicFileBytesWithCapability ([string]$action.targetPath) ([byte[]]$state.desiredRegistryBytes) $true ([string]$action.beforeSha256) ([string]$action.afterSha256) ([string]$Profile.codexHome) @([string]$action.targetPath) 'production full registry publish'}else{throw 'production full action kind 非法。'}
                $completed.Add([string]$action.actionId)
            }
            $status.status='applied';$status.completedActionIds=[string[]]$completed.ToArray();Set-CodexHookProductionFullJson ([string]$paths.statusPath) $status $Profile
            $active.state='applied'
            Set-CodexHookProductionFullJson ([string]$paths.activePath) $active $Profile
        } catch {
            $status.completedActionIds=[string[]]$completed.ToArray();$status.status='rollback-pending';Set-CodexHookProductionFullJson ([string]$paths.statusPath) $status $Profile
            [void](Restore-CodexHookProductionFullEngine -Profile $Profile -EvidenceDirectory ([string]$paths.evidenceDirectory) -EnvironmentReadValue $EnvironmentReadValue -EnvironmentWriteValue $EnvironmentWriteValue -FinalStatus rolled-back)
            throw 'production full apply 失败；自动 rollback 完成。'
        }
        return [pscustomobject][ordered]@{applied=$true;noOp=$false;generationId=[string]$plan.generationId;evidenceDirectory=[string]$paths.evidenceDirectory}
    } finally {if($null -ne $lease){Exit-CodexHookProductionFullMutex -Lease $lease}}
}

function Remove-CodexHookProductionFullFile {
    param([string]$Path,[string]$ExpectedSha256,[object]$Profile)
    Remove-CodexHookCapabilityFile -Path $Path -ExpectedSha256 $ExpectedSha256 -CapabilityRoot ([string]$Profile.hooksRoot) -AllowedExactPaths @($Path) -Scope 'production full restore remove'
}

function Restore-CodexHookProductionFullEngine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Profile,
        [Parameter(Mandatory)][string]$EvidenceDirectory,
        [Parameter(Mandatory)][scriptblock]$EnvironmentReadValue,
        [Parameter(Mandatory)][scriptblock]$EnvironmentWriteValue,
        [ValidateSet('restored','rolled-back')][string]$FinalStatus='restored',
        [scriptblock]$TestAfterRestoreAction,
        [scriptblock]$TestBeforeEnvironmentRestoreWrite
    )
    if(($null -ne $TestAfterRestoreAction -or $null -ne $TestBeforeEnvironmentRestoreWrite) -and -not $Profile.isFixtureAdapter){throw 'production full restore fault seam 仅允许 fixture adapter。'}
    [void](Assert-CodexHookProductionFullProfile -Profile $Profile -AllowFixtureAdapter)
    $evidence=Assert-CodexHookCapabilityPath $EvidenceDirectory ([string]$Profile.evidenceRoot) @() 'production full evidence'
    $restorePath=Join-Path $evidence 'restore-manifest.json'
    $identitySnapshot=Get-CodexHookCapabilityFileSnapshot $restorePath ([string]$Profile.evidenceRoot) @($restorePath) 'production full restore identity'
    $identityText=[Text.UTF8Encoding]::new($false,$true).GetString([byte[]]$identitySnapshot.bytes);Assert-CodexHookStrictJsonText $identityText;$identity=$identityText|ConvertFrom-Json -Depth 128
    Assert-CodexHookExactProperties $identity @('artifactType','schemaVersion','profileId','generationId','planSha256','mappingIdentity','manifestBackupRelativePath','manifestBackupSha256','previousActiveBackupRelativePath','previousActiveBackupSha256','actions') 'production full restore identity'
    if($identity.artifactType -cne 'env-governance.codex-hook-production-full-restore' -or [int]$identity.schemaVersion -ne 1 -or $identity.profileId -cne $Profile.profileId){throw 'production full restore schema/binding 非法。'}
    $paths=Get-CodexHookProductionFullLifecyclePaths $Profile ([string]$identity.generationId)
    if([IO.Path]::GetFullPath($evidence)-ine[IO.Path]::GetFullPath([string]$paths.evidenceDirectory)){throw 'production full evidence mapping 非法。'}
    $lease=$null
    try{
        $lease=Enter-CodexHookProductionFullMutex -Name ([string]$Profile.mutexName)
        $rs=Get-CodexHookCapabilityFileSnapshot $restorePath ([string]$Profile.evidenceRoot) @($restorePath) 'production full restore manifest'
        if($rs.sha256 -cne $identitySnapshot.sha256){throw 'production full restore manifest mutex 前后漂移。'}
        $restore=([Text.UTF8Encoding]::new($false,$true).GetString([byte[]]$rs.bytes))|ConvertFrom-Json -Depth 128
        Assert-CodexHookExactProperties $restore @('artifactType','schemaVersion','profileId','generationId','planSha256','mappingIdentity','manifestBackupRelativePath','manifestBackupSha256','previousActiveBackupRelativePath','previousActiveBackupSha256','actions') 'production full restore manifest'
        if($restore.mappingIdentity -cne (Get-CodexHookProductionFullMappingIdentity $Profile) -or [string]$restore.planSha256 -cnotmatch '^[0-9a-f]{64}$'){throw 'production full restore binding 非法。'}
        $claimPath=[string]$paths.claimPath
        $cs=Get-CodexHookCapabilityFileSnapshot $claimPath ([string]$Profile.evidenceRoot) @($claimPath) 'production full claim'
        $claim=([Text.UTF8Encoding]::new($false,$true).GetString([byte[]]$cs.bytes))|ConvertFrom-Json -Depth 32
        Assert-CodexHookExactProperties $claim @('artifactType','schemaVersion','profileId','state','generationId','mappingIdentity','planSha256','evidenceDirectory','restoreManifestSha256','attestationSha256') 'production full claim'
        if($claim.artifactType -cne 'env-governance.codex-hook-deployment-claim' -or [int]$claim.schemaVersion -ne 1 -or $claim.profileId -cne $Profile.profileId -or $claim.state -cne 'prepared' -or $claim.generationId -cne $restore.generationId -or $claim.mappingIdentity -cne $restore.mappingIdentity -or $claim.planSha256 -cne $restore.planSha256 -or $claim.evidenceDirectory -cne $evidence -or $claim.restoreManifestSha256 -cne $rs.sha256){throw 'production full claim/restore hash binding 非法。'}
        $attestationSnapshot=Get-CodexHookCapabilityFileSnapshot ([string]$paths.attestationPath) ([string]$Profile.evidenceRoot) @([string]$paths.attestationPath) 'production full evidence attestation'
        if($attestationSnapshot.sha256 -cne $claim.attestationSha256){throw 'production full evidence attestation hash 非法。'}
        $attestationEnvelope=([Text.UTF8Encoding]::new($false,$true).GetString([byte[]]$attestationSnapshot.bytes))|ConvertFrom-Json -Depth 20
        $attestation=Unprotect-CodexHookProductionFullAttestation $attestationEnvelope
        Assert-CodexHookExactProperties $attestation @('artifactType','schemaVersion','profileId','claimState','generationId','mappingIdentity','planSha256','evidenceDirectory','restoreManifestSha256','manifestBackupSha256','previousActiveBackupSha256') 'production full evidence attestation'
        if($attestation.artifactType -cne 'env-governance.codex-hook-production-full-attestation' -or [int]$attestation.schemaVersion -ne 1 -or $attestation.profileId -cne $claim.profileId -or $attestation.claimState -cne $claim.state -or $attestation.generationId -cne $claim.generationId -or $attestation.mappingIdentity -cne $claim.mappingIdentity -or $attestation.planSha256 -cne $claim.planSha256 -or $attestation.evidenceDirectory -cne $evidence -or $attestation.restoreManifestSha256 -cne $rs.sha256 -or $attestation.manifestBackupSha256 -cne $restore.manifestBackupSha256 -or $attestation.previousActiveBackupSha256 -cne $restore.previousActiveBackupSha256){throw 'production full evidence attestation 认证绑定非法。'}
        $statusPath=[string]$paths.statusPath;$ss=Get-CodexHookCapabilityFileSnapshot $statusPath ([string]$Profile.evidenceRoot) @($statusPath) 'production full status';$st=([Text.UTF8Encoding]::new($false,$true).GetString([byte[]]$ss.bytes))|ConvertFrom-Json -Depth 32
        Assert-CodexHookExactProperties $st @('artifactType','schemaVersion','profileId','generationId','status','completedActionIds','restoredActionIds') 'production full status'
        if($st.artifactType -cne 'env-governance.codex-hook-production-full-status' -or [int]$st.schemaVersion -ne 1 -or $st.profileId -cne $Profile.profileId -or $st.generationId -cne $restore.generationId -or $st.status -cnotin @('applying','rollback-pending','applied','restoring','rolled-back','restored')){throw 'production full status binding 非法。'}
        $as=Get-CodexHookCapabilityFileSnapshot ([string]$paths.activePath) ([string]$Profile.evidenceRoot) @([string]$paths.activePath) 'production full active generation';$active=([Text.UTF8Encoding]::new($false,$true).GetString([byte[]]$as.bytes))|ConvertFrom-Json -Depth 16
        Assert-CodexHookExactProperties $active @('artifactType','schemaVersion','profileId','generationId','evidenceDirectory','state','previousGenerationId','previousEvidenceDirectory') 'production full active generation'
        if($active.artifactType -cne 'env-governance.codex-hook-production-full-active' -or [int]$active.schemaVersion -ne 1 -or $active.profileId -cne $Profile.profileId -or $active.generationId -cne $restore.generationId -or $active.evidenceDirectory -cne $evidence -or $active.state -cnotin @('applying','applied','restored','rolled-back')){throw 'production full active generation binding 非法。'}
        $previousActiveBackup=$null
        if($null -ne $active.previousGenerationId){
            if($null -eq $restore.previousActiveBackupRelativePath -or $null -eq $restore.previousActiveBackupSha256){throw 'production full predecessor backup 缺失。'}
            $previousActiveBackupPath=Join-Path $evidence ([string]$restore.previousActiveBackupRelativePath)
            if(-not(Test-CodexHookPathWithin $previousActiveBackupPath ([string]$paths.backupsRoot))){throw 'production full predecessor backup 越界。'}
            $previousActiveBackup=Get-CodexHookCapabilityFileSnapshot $previousActiveBackupPath ([string]$Profile.evidenceRoot) @($previousActiveBackupPath) 'production full predecessor backup'
            if($previousActiveBackup.sha256 -cne $restore.previousActiveBackupSha256){throw 'production full predecessor backup hash 非法。'}
            $previousPointer=([Text.UTF8Encoding]::new($false,$true).GetString([byte[]]$previousActiveBackup.bytes))|ConvertFrom-Json -Depth 16
            Assert-CodexHookExactProperties $previousPointer @('artifactType','schemaVersion','profileId','generationId','evidenceDirectory','state','previousGenerationId','previousEvidenceDirectory') 'production full predecessor pointer'
            if($previousPointer.generationId -cne $active.previousGenerationId -or $previousPointer.evidenceDirectory -cne $active.previousEvidenceDirectory){throw 'production full predecessor pointer binding 非法。'}
        }elseif($null -ne $restore.previousActiveBackupRelativePath -or $null -ne $restore.previousActiveBackupSha256){throw 'production full unexpected predecessor backup。'}
        $manifestBackupPath=Join-Path $evidence ([string]$restore.manifestBackupRelativePath)
        if(-not(Test-CodexHookPathWithin $manifestBackupPath ([string]$paths.backupsRoot))){throw 'production full manifest backup 越界。'}
        $manifestSnapshot=Get-CodexHookCapabilityFileSnapshot $manifestBackupPath ([string]$Profile.evidenceRoot) @($manifestBackupPath) 'production full restore manifest policy'
        if($manifestSnapshot.sha256 -cne $restore.manifestBackupSha256){throw 'production full manifest backup hash 非法。'}
        $manifest=([Text.UTF8Encoding]::new($false,$true).GetString([byte[]]$manifestSnapshot.bytes))|ConvertFrom-Json -Depth 128
        [void](Assert-CodexHookManifest $manifest)
        $allowed=@{}
        foreach($file in @($manifest.files|Where-Object lifecycle -cne 'retired')){
            $id="file:$([string]$file.relativePath -replace '\\','/')"
            $path=[IO.Path]::GetFullPath((Join-Path ([string]$Profile.hooksRoot) ([string]$file.liveRelativePath)))
            $allowed[$id]=[pscustomobject]@{kind='file';path=$path}
        }
        $allowed['environment:User:SERENA_HOME']=[pscustomobject]@{kind='environment';path=$null}
        $allowed['registry:hooks.json']=[pscustomobject]@{kind='registry';path=[string]$Profile.registryPath}
        if(@($restore.actions).Count -ne $allowed.Count){throw 'production full restore action count 非法。'}
        $preflight=[Collections.Generic.List[object]]::new();$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($a in @($restore.actions)){
            Assert-CodexHookExactProperties $a @('actionId','kind','path','beforeExists','beforeSha256','backupRelativePath','backupSha256','deployedSha256','restoreOrder') 'production full restore action'
            $id=[string]$a.actionId
            if(-not $allowed.ContainsKey($id)-or-not $seen.Add($id)){throw 'production full restore action allowlist 非法。'}
            $pathMismatch=if($null -eq $allowed[$id].path){$null -ne $a.path}else{[IO.Path]::GetFullPath([string]$a.path)-ine[IO.Path]::GetFullPath([string]$allowed[$id].path)}
            if($a.kind -cne $allowed[$id].kind -or $pathMismatch){throw 'production full restore action allowlist 非法。'}
            if($a.kind -ceq 'environment'){
                $bp=Join-Path $evidence ([string]$a.backupRelativePath)
                if(-not(Test-CodexHookPathWithin $bp ([string]$paths.backupsRoot))){throw 'production full env backup 越界。'}
                $b=Get-CodexHookCapabilityFileSnapshot $bp ([string]$Profile.evidenceRoot) @($bp) 'production full env backup'
                if($b.sha256 -cne $a.backupSha256){throw 'production full env backup hash 非法。'}
                $protected=([Text.UTF8Encoding]::new($false,$true).GetString([byte[]]$b.bytes))|ConvertFrom-Json
                $before=Unprotect-CodexHookProductionFullEnvironmentBackup $protected
                $beforeHash=Get-CodexHookTextSha256 -Text $(if($before.present){"present`0$($before.value)"}else{'absent'})
                $cur=Get-CodexHookProductionFullEnvironmentFact $EnvironmentReadValue
                $state=if($cur.valueSha256 -ceq $beforeHash){'before'}elseif($cur.valueSha256 -ceq $a.deployedSha256){'deployed'}else{'drift'}
                $preflight.Add([pscustomobject]@{action=$a;state=$state;backup=$before;beforeHash=$beforeHash})
                continue
            }
            $cap=if($a.kind -ceq 'registry'){[string]$Profile.codexHome}else{[string]$Profile.hooksRoot}
            $cur=Get-CodexHookCapabilityFileSnapshot ([string]$a.path) $cap @([string]$a.path) 'production full restore target'
            $isBefore=if($a.beforeExists){$cur.exists -and $cur.sha256 -ceq $a.beforeSha256}else{-not $cur.exists}
            $state=if($isBefore){'before'}elseif($cur.exists -and $cur.sha256 -ceq $a.deployedSha256){'deployed'}else{'drift'}
            $backup=$null
            if($a.beforeExists){
                $bp=Join-Path $evidence ([string]$a.backupRelativePath)
                if(-not(Test-CodexHookPathWithin $bp ([string]$paths.backupsRoot))){throw 'production full backup 越界。'}
                $backup=Get-CodexHookCapabilityFileSnapshot $bp ([string]$Profile.evidenceRoot) @($bp) 'production full restore backup'
                if($backup.sha256 -cne $a.backupSha256 -or $backup.sha256 -cne $a.beforeSha256){throw 'production full restore backup hash 非法。'}
            }elseif($null -ne $a.backupRelativePath -or $null -ne $a.backupSha256){throw 'production full missing-before backup 非法。'}
            $preflight.Add([pscustomobject]@{action=$a;state=$state;backup=$backup;capability=$cap})
        }
        if(@($preflight|Where-Object state -ceq 'drift').Count){throw 'production full restore preflight 检测到 target 漂移；零写拒绝。'}
        $hasDeployed=@($preflight|Where-Object state -ceq 'deployed').Count -gt 0
        if($st.status -cin @('restored','rolled-back') -and $hasDeployed){throw 'production full terminal status 不相容；零写拒绝。'}
        if($st.status -cin @('restored','rolled-back') -and -not $hasDeployed){return [pscustomobject][ordered]@{restored=$false;noOp=$true;terminalStatus=[string]$st.status;evidenceDirectory=$evidence}}
        $restoredIds=[Collections.Generic.List[string]]::new()
        foreach($id in @($st.restoredActionIds)){if($id -isnot [string] -or -not $seen.Contains([string]$id) -or $restoredIds.Contains([string]$id)){throw 'production full restore progress 非法。'};$restoredIds.Add([string]$id)}
        $changed=$false
        foreach($item in @($preflight|Sort-Object {- [int]$_.action.restoreOrder})){
            $a=$item.action
            if($item.state -ceq 'deployed'){
                if($a.kind -ceq 'environment'){
                    $environmentBeforeWrite=Get-CodexHookProductionFullEnvironmentFact $EnvironmentReadValue
                    if($environmentBeforeWrite.valueSha256 -cne $a.deployedSha256){throw 'production full environment restore CAS 失败。'}
                    if($null -ne $TestBeforeEnvironmentRestoreWrite){& $TestBeforeEnvironmentRestoreWrite ([string]$a.actionId)}
                    $environmentCommitRead=Get-CodexHookProductionFullEnvironmentFact $EnvironmentReadValue
                    if($environmentCommitRead.valueSha256 -cne $a.deployedSha256){throw 'production full environment restore CAS 失败。'}
                    Invoke-CodexHookProductionFullEnvironmentWrite $EnvironmentWriteValue $(if($item.backup.present){[string]$item.backup.value}else{$null})
                    $environmentAfterWrite=Get-CodexHookProductionFullEnvironmentFact $EnvironmentReadValue
                    if($environmentAfterWrite.valueSha256 -cne $item.beforeHash){throw 'production full environment restore postcheck 失败。'}
                }elseif($a.beforeExists){
                    Set-CodexHookAtomicFileBytesWithCapability ([string]$a.path) ([byte[]]$item.backup.bytes) $true ([string]$a.deployedSha256) ([string]$a.beforeSha256) ([string]$item.capability) @([string]$a.path) 'production full restore publish'
                }else{
                    Remove-CodexHookProductionFullFile ([string]$a.path) ([string]$a.deployedSha256) $Profile
                }
                $changed=$true
            }
            if(-not $restoredIds.Contains([string]$a.actionId)){$restoredIds.Add([string]$a.actionId)}
            $st.status='restoring'
            $st.restoredActionIds=[string[]]$restoredIds.ToArray()
            Set-CodexHookProductionFullJson $statusPath $st $Profile
            if($null -ne $TestAfterRestoreAction){& $TestAfterRestoreAction ([string]$a.actionId)}
        }
        $terminal=if($FinalStatus -ceq 'rolled-back'){'rolled-back'}else{'restored'};$st.status=$terminal;Set-CodexHookProductionFullJson $statusPath $st $Profile
        if($null -ne $previousActiveBackup){
            $currentActiveSnapshot=Get-CodexHookCapabilityFileSnapshot ([string]$paths.activePath) ([string]$Profile.evidenceRoot) @([string]$paths.activePath) 'production full active predecessor publish'
            Set-CodexHookAtomicFileBytesWithCapability ([string]$paths.activePath) ([byte[]]$previousActiveBackup.bytes) $true ([string]$currentActiveSnapshot.sha256) ([string]$previousActiveBackup.sha256) ([string]$Profile.evidenceRoot) @([string]$paths.activePath) 'production full active predecessor publish'
        }else{
            $active.state=$terminal
            Set-CodexHookProductionFullJson ([string]$paths.activePath) $active $Profile
        }
        return [pscustomobject][ordered]@{restored=$changed;noOp=-not $changed;terminalStatus=$terminal;evidenceDirectory=$evidence}
    }finally{if($null -ne $lease){Exit-CodexHookProductionFullMutex -Lease $lease}}
}

function Invoke-CodexHookProductionFullApplyCore {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Profile,[Parameter(Mandatory)][scriptblock]$EnvironmentReadValue,[Parameter(Mandatory)][scriptblock]$EnvironmentWriteValue,[ValidateSet('none','before-registry')][string]$TestFaultInjection='none')
    [void](Assert-CodexHookProductionFullProfile -Profile $Profile -AllowFixtureAdapter)
    if(-not $Profile.isFixtureAdapter){throw 'production full core adapters 仅允许 fixed fixture；真实 production 必须使用固定 façade。'}
    return Invoke-CodexHookProductionFullApplyEngine -Profile $Profile -EnvironmentReadValue $EnvironmentReadValue -EnvironmentWriteValue $EnvironmentWriteValue -TestFaultInjection $TestFaultInjection
}

function Restore-CodexHookProductionFullCore {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Profile,[Parameter(Mandatory)][string]$EvidenceDirectory,[Parameter(Mandatory)][scriptblock]$EnvironmentReadValue,[Parameter(Mandatory)][scriptblock]$EnvironmentWriteValue,[ValidateSet('restored','rolled-back')][string]$FinalStatus='restored',[scriptblock]$TestAfterRestoreAction,[scriptblock]$TestBeforeEnvironmentRestoreWrite)
    [void](Assert-CodexHookProductionFullProfile -Profile $Profile -AllowFixtureAdapter)
    if(-not $Profile.isFixtureAdapter){throw 'production full restore core adapters 仅允许 fixed fixture；真实 production 必须使用固定 façade。'}
    return Restore-CodexHookProductionFullEngine -Profile $Profile -EvidenceDirectory $EvidenceDirectory -EnvironmentReadValue $EnvironmentReadValue -EnvironmentWriteValue $EnvironmentWriteValue -FinalStatus $FinalStatus -TestAfterRestoreAction $TestAfterRestoreAction -TestBeforeEnvironmentRestoreWrite $TestBeforeEnvironmentRestoreWrite
}

function Invoke-CodexHookProductionFullApply {
    [CmdletBinding()]
    param()
    $profile=Get-CodexHookProductionFullProfile
    $read={param($Name,$Scope)[Environment]::GetEnvironmentVariable($Name,[EnvironmentVariableTarget]::User)}
    $write={param($Name,$Scope,$Value)[Environment]::SetEnvironmentVariable($Name,$Value,[EnvironmentVariableTarget]::User)}
    return Invoke-CodexHookProductionFullApplyEngine -Profile $profile -EnvironmentReadValue $read -EnvironmentWriteValue $write
}

function Restore-CodexHookProductionFull {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$EvidenceDirectory)
    $profile=Get-CodexHookProductionFullProfile
    $read={param($Name,$Scope)[Environment]::GetEnvironmentVariable($Name,[EnvironmentVariableTarget]::User)}
    $write={param($Name,$Scope,$Value)[Environment]::SetEnvironmentVariable($Name,$Value,[EnvironmentVariableTarget]::User)}
    return Restore-CodexHookProductionFullEngine -Profile $profile -EvidenceDirectory $EvidenceDirectory -EnvironmentReadValue $read -EnvironmentWriteValue $write
}
