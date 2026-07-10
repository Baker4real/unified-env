$backupRetentionValidationRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $backupRetentionValidationRoot 'lib\BackupRetentionPolicy.ps1')

function Assert-BackupRetentionProperty {
    param([Parameter(Mandatory)][object]$Object,[Parameter(Mandatory)][string]$Name,[string]$Scope='document')
    if ($null -eq $Object -or $Object.PSObject.Properties.Name -notcontains $Name) { throw "$Scope 缺少必需属性：$Name" }
    return $Object.$Name
}
function Assert-BackupRetentionString {
    param([object]$Value,[string]$Name,[switch]$AllowEmpty)
    if ($Value -isnot [string] -or (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace($Value))) { throw "$Name 必须是 JSON string。" }
}
function Assert-BackupRetentionBoolean { param([object]$Value,[string]$Name) if ($Value -isnot [bool]) { throw "$Name 必须是 JSON boolean。" } }
function Assert-BackupRetentionInteger {
    param([object]$Value,[string]$Name)
    if ($Value -isnot [sbyte] -and $Value -isnot [byte] -and $Value -isnot [int16] -and $Value -isnot [uint16] -and $Value -isnot [int32] -and $Value -isnot [uint32] -and $Value -isnot [int64] -and $Value -isnot [uint64]) { throw "$Name 必须是 JSON integer。" }
}
function Assert-BackupRetentionArray { param([object]$Value,[string]$Name) if ($Value -isnot [array]) { throw "$Name 必须是 JSON array。" } }
function Assert-BackupRetentionExactProperties {
    param([object]$Object,[string[]]$Names,[string]$Scope)
    if($null-eq$Object-or$Object-is[string]-or$Object-is[array]-or$Object.GetType().IsPrimitive){throw "$Scope 必须是 JSON object。"}
    $actual=@($Object.PSObject.Properties.Name)
    if($actual.Count-ne$Names.Count){throw "$Scope 属性集合不精确：expected=$($Names-join','), actual=$($actual-join',')"}
    $expectedSet=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($name in $Names){[void]$expectedSet.Add($name)}
    foreach($name in $actual){if(-not$expectedSet.Remove($name)){throw "$Scope 包含未知或重复属性：$name"}}
    if($expectedSet.Count-ne0){throw "$Scope 缺少属性：$(@($expectedSet)-join',')"}
}
function Assert-BackupRetentionNullableString { param([object]$Value,[string]$Name) if($null-ne$Value-and$Value-isnot[string]){throw "$Name 必须是 JSON string 或 null。"} }
function Assert-BackupRetentionNullableBoolean { param([object]$Value,[string]$Name) if($null-ne$Value-and$Value-isnot[bool]){throw "$Name 必须是 JSON boolean 或 null。"} }
function Assert-BackupRetentionNullableInteger { param([object]$Value,[string]$Name) if($null-ne$Value){Assert-BackupRetentionInteger $Value $Name} }
function Assert-BackupRetentionNumber {
    param([object]$Value,[string]$Name)
    if($Value-isnot[sbyte]-and$Value-isnot[byte]-and$Value-isnot[int16]-and$Value-isnot[uint16]-and$Value-isnot[int32]-and$Value-isnot[uint32]-and$Value-isnot[int64]-and$Value-isnot[uint64]-and$Value-isnot[single]-and$Value-isnot[double]-and$Value-isnot[decimal]){throw "$Name 必须是 JSON number。"}
}
function Assert-BackupRetentionStringArray {
    param([object]$Value,[string]$Name)
    Assert-BackupRetentionArray ([object]$Value) $Name
    foreach($item in @($Value)){Assert-BackupRetentionString $item "$Name[]" -AllowEmpty}
}
function Assert-BackupRetentionJsonElementUniqueProperties {
    param([Parameter(Mandatory)][System.Text.Json.JsonElement]$Element,[string]$Path='$')
    if($Element.ValueKind-eq[System.Text.Json.JsonValueKind]::Object){
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($property in $Element.EnumerateObject()){
            if(-not$seen.Add($property.Name)){throw "重复 JSON 属性：$Path.$($property.Name)"}
            Assert-BackupRetentionJsonElementUniqueProperties -Element $property.Value -Path "$Path.$($property.Name)"
        }
    }elseif($Element.ValueKind-eq[System.Text.Json.JsonValueKind]::Array){
        $index=0;foreach($item in $Element.EnumerateArray()){Assert-BackupRetentionJsonElementUniqueProperties -Element $item -Path "$Path[$index]";$index++}
    }
}
function Assert-BackupRetentionStrictJsonText {
    param([Parameter(Mandatory)][string]$JsonText)
    $options=[System.Text.Json.JsonDocumentOptions]::new();$options.AllowTrailingCommas=$false;$options.CommentHandling=[System.Text.Json.JsonCommentHandling]::Disallow;$options.MaxDepth=128
    try{$document=[System.Text.Json.JsonDocument]::Parse($JsonText,$options)}catch{throw "严格 JSON 词法校验失败：$($_.Exception.Message)"}
    try{Assert-BackupRetentionJsonElementUniqueProperties -Element $document.RootElement}finally{$document.Dispose()}
}
function Get-BackupRetentionValidationPathKey { param([object]$Value,[string]$Name) Assert-BackupRetentionString $Value $Name; return (Get-BackupRetentionCanonicalPath -Path $Value).ToLowerInvariant() }
function ConvertTo-BackupRetentionSemanticJson { param([object]$Value) return (ConvertTo-Json -InputObject $Value -Depth 100 -Compress) }

function Assert-BackupRetentionStatsSchema {
    param([object]$Stats,[string]$Scope,[bool]$RequireTreeDigest=$false)
    Assert-BackupRetentionExactProperties $Stats @('exists','bytes','mb','files','dirs','skillMd','newestUtc','oldestUtc','reparsePointsSkipped','inaccessibleItems','treeSha256') $Scope
    Assert-BackupRetentionNullableBoolean $Stats.exists "$Scope.exists"
    foreach($name in @('bytes','files','dirs','skillMd','reparsePointsSkipped','inaccessibleItems')){Assert-BackupRetentionInteger $Stats.$name "$Scope.$name"}
    Assert-BackupRetentionNumber $Stats.mb "$Scope.mb"
    foreach($name in @('newestUtc','oldestUtc','treeSha256')){Assert-BackupRetentionNullableString $Stats.$name "$Scope.$name"}
    if($null-ne$Stats.treeSha256-and$Stats.treeSha256-notmatch'^[0-9a-f]{64}$'){throw "$Scope.treeSha256 必须是 lowercase SHA-256 或 null。"}
    if($RequireTreeDigest-and$Stats.treeSha256-notmatch'^[0-9a-f]{64}$'){throw "$Scope.treeSha256 是 candidate 必需字段。"}
}
function Assert-BackupRetentionItemSchema {
    param([object]$Item,[string]$Scope)
    $names=@('path','scanRoot','itemType','coverageOrigin','coverageDisposition','coverageAccounted','requiresManualReview','blocksCoverage','reason','rule','bucket','groupKey','projectRoot','backupType','timestampUtc','timestampSource','retainRank','risk','metadataStatus','errors','delegatedScanRoot','isReparsePoint','reparseTarget','reparseAncestor','reparse','automaticCandidate','selectedByRetention','applyEligible','requiresExplicitAuthorization','blockedBy','stats')
    Assert-BackupRetentionExactProperties $Item $names $Scope
    foreach($name in @('path','itemType','coverageOrigin','coverageDisposition','reason','rule','bucket','groupKey','projectRoot','backupType','risk','metadataStatus')){Assert-BackupRetentionString $Item.$name "$Scope.$name" -AllowEmpty}
    foreach($name in @('scanRoot','timestampUtc','timestampSource','delegatedScanRoot','reparseTarget','reparseAncestor')){Assert-BackupRetentionNullableString $Item.$name "$Scope.$name"}
    Assert-BackupRetentionNullableInteger $Item.retainRank "$Scope.retainRank"
    foreach($name in @('coverageAccounted','requiresManualReview','blocksCoverage','automaticCandidate','selectedByRetention','applyEligible','requiresExplicitAuthorization')){Assert-BackupRetentionBoolean $Item.$name "$Scope.$name"}
    Assert-BackupRetentionNullableBoolean $Item.isReparsePoint "$Scope.isReparsePoint"
    Assert-BackupRetentionStringArray ([object]$Item.errors) "$Scope.errors";Assert-BackupRetentionStringArray ([object]$Item.blockedBy) "$Scope.blockedBy"
    Assert-BackupRetentionExactProperties $Item.reparse @('isReparsePoint','hasReparsePoint','firstReparsePoint','target') "$Scope.reparse"
    Assert-BackupRetentionNullableBoolean $Item.reparse.isReparsePoint "$Scope.reparse.isReparsePoint";Assert-BackupRetentionBoolean $Item.reparse.hasReparsePoint "$Scope.reparse.hasReparsePoint"
    Assert-BackupRetentionNullableString $Item.reparse.firstReparsePoint "$Scope.reparse.firstReparsePoint";Assert-BackupRetentionNullableString $Item.reparse.target "$Scope.reparse.target"
    if($null-ne$Item.stats){Assert-BackupRetentionStatsSchema $Item.stats "$Scope.stats" ($Item.coverageDisposition-ceq'candidate')}
    elseif($Item.coverageDisposition-ceq'candidate'){throw "$Scope.stats 是 candidate 必需对象。"}
}
function Get-BackupRetentionEvaluationSummary {
    param([Parameter(Mandatory)][psobject]$Evaluation)
    $candidateBytes=[int64](($Evaluation.candidates|ForEach-Object{if($null-ne$_.stats){[int64]$_.stats.bytes}else{0}}|Measure-Object -Sum).Sum)
    $manualBytes=[int64](($Evaluation.manualReview|ForEach-Object{if($null-ne$_.stats){[int64]$_.stats.bytes}else{0}}|Measure-Object -Sum).Sum)
    return [pscustomobject][ordered]@{
        declaredScanRootCount=@($Evaluation.declaredScanRoots).Count;evaluatedRootCount=@($Evaluation.evaluatedRoots).Count;coverageItemCount=@($Evaluation.coverageItems).Count
        candidateCount=@($Evaluation.candidates).Count;retainedCount=@($Evaluation.retainedItems).Count;protectedCount=@($Evaluation.protected).Count;manualReviewCount=@($Evaluation.manualReview).Count;gapCount=@($Evaluation.unclassifiedCoverageGaps).Count
        candidateBytes=$candidateBytes;candidateMb=[math]::Round($candidateBytes/1MB,2);manualReviewBytes=$manualBytes;manualReviewMb=[math]::Round($manualBytes/1MB,2)
        candidateSkillMd=[int](($Evaluation.candidates|ForEach-Object{if($null-ne$_.stats){[int]$_.stats.skillMd}else{0}}|Measure-Object -Sum).Sum);selectedByRetentionCount=@($Evaluation.candidates).Count
        lowRiskCount=@($Evaluation.candidates|Where-Object risk -eq '低').Count;mediumRiskCount=@($Evaluation.candidates|Where-Object risk -eq '中').Count;highRiskCount=@($Evaluation.candidates|Where-Object risk -eq '高').Count
        byBucket=[object[]]@($Evaluation.candidates|Group-Object bucket|ForEach-Object{[pscustomobject]@{bucket=$_.Name;count=$_.Count}})
        manualByBucket=[object[]]@($Evaluation.manualReview|Group-Object bucket|ForEach-Object{[pscustomobject]@{bucket=$_.Name;count=$_.Count}})
    }
}
function Assert-BackupRetentionSummarySchema {
    param([object]$Summary,[string]$Scope)
    $names=@('declaredScanRootCount','evaluatedRootCount','coverageItemCount','candidateCount','retainedCount','protectedCount','manualReviewCount','gapCount','candidateBytes','candidateMb','manualReviewBytes','manualReviewMb','candidateSkillMd','selectedByRetentionCount','lowRiskCount','mediumRiskCount','highRiskCount','byBucket','manualByBucket')
    Assert-BackupRetentionExactProperties $Summary $names $Scope
    foreach($name in @('declaredScanRootCount','evaluatedRootCount','coverageItemCount','candidateCount','retainedCount','protectedCount','manualReviewCount','gapCount','candidateBytes','manualReviewBytes','candidateSkillMd','selectedByRetentionCount','lowRiskCount','mediumRiskCount','highRiskCount')){Assert-BackupRetentionInteger $Summary.$name "$Scope.$name"}
    foreach($name in @('candidateMb','manualReviewMb')){Assert-BackupRetentionNumber $Summary.$name "$Scope.$name"}
    foreach($name in @('byBucket','manualByBucket')){Assert-BackupRetentionArray ([object]$Summary.$name) "$Scope.$name";foreach($entry in @($Summary.$name)){Assert-BackupRetentionExactProperties $entry @('bucket','count') "$Scope.$name[]";Assert-BackupRetentionString $entry.bucket "$Scope.$name[].bucket" -AllowEmpty;Assert-BackupRetentionInteger $entry.count "$Scope.$name[].count"}}
}

function Get-BackupRetentionRootSemanticProjection {
    param([object]$Root)
    return [pscustomobject][ordered]@{
        rootId=$Root.rootId;path=$Root.path;rule=$Root.rule;metadataStatus=$Root.metadataStatus;exists=$Root.exists
        rootIsReparsePoint=$Root.rootIsReparsePoint;reparseAncestor=$Root.reparseAncestor;reparseTarget=$Root.reparseTarget
        enumerationCompleted=$Root.enumerationCompleted;errors=[object[]]@($Root.errors);directChildCount=$Root.directChildCount
        directChildren=[object[]]@($Root.directChildren);snapshotSha256=$Root.snapshotSha256;classificationCount=$Root.classificationCount
        classificationCounts=$Root.classificationCounts
    }
}
function Get-BackupRetentionItemSemanticProjection {
    param([object]$Item)
    $ordered=[ordered]@{}
    foreach($name in @('path','scanRoot','itemType','coverageOrigin','coverageDisposition','coverageAccounted','requiresManualReview','blocksCoverage','reason','rule','bucket','groupKey','projectRoot','backupType','timestampUtc','timestampSource','retainRank','risk','metadataStatus','errors','delegatedScanRoot','isReparsePoint','reparseTarget','reparseAncestor','reparse','automaticCandidate','selectedByRetention','applyEligible','requiresExplicitAuthorization','blockedBy','stats')) {
        $ordered[$name]=$Item.$name
    }
    return [pscustomobject]$ordered
}
function Assert-BackupRetentionUniquePaths {
    param([object[]]$Items,[string]$Name)
    $seen=@{}
    foreach($item in $Items){
        $path=Assert-BackupRetentionProperty $item 'path' $Name; $key=Get-BackupRetentionValidationPathKey $path "$Name.path"
        if($seen.ContainsKey($key)){throw "$Name 包含重复 canonical path：$path"};$seen[$key]=$true
    }
}
function Compare-BackupRetentionPathCollection {
    param([object[]]$Expected,[object[]]$Actual,[string]$Name,[scriptblock]$Projection)
    Assert-BackupRetentionUniquePaths $Expected "expected $Name"; Assert-BackupRetentionUniquePaths $Actual $Name
    $actualMap=@{};foreach($item in $Actual){$actualMap[(Get-BackupRetentionValidationPathKey $item.path "$Name.path")]=$item}
    if($Expected.Count-ne$Actual.Count){throw "$Name 数量与现场复算不一致。"}
    foreach($expectedItem in $Expected){
        $key=Get-BackupRetentionValidationPathKey $expectedItem.path "expected $Name.path"
        if(-not $actualMap.ContainsKey($key)){throw "$Name 缺少现场路径：$($expectedItem.path)"}
        $expectedJson=ConvertTo-BackupRetentionSemanticJson (& $Projection $expectedItem)
        $actualJson=ConvertTo-BackupRetentionSemanticJson (& $Projection $actualMap[$key])
        if($expectedJson-cne$actualJson){throw "$Name 语义或现场快照不一致：$($expectedItem.path)"}
    }
}

function Compare-BackupRetentionEvaluation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Document,[Parameter(Mandatory)][psobject]$LiveEvaluation)

    $declaredProjection={param($x)[pscustomobject][ordered]@{rootId=$x.rootId;path=$x.path;rule=$x.rule}}
    Compare-BackupRetentionPathCollection -Expected @($LiveEvaluation.declaredScanRoots) -Actual @($Document.declaredScanRoots) -Name 'declaredScanRoots' -Projection $declaredProjection
    Compare-BackupRetentionPathCollection -Expected @($LiveEvaluation.evaluatedRoots) -Actual @($Document.evaluatedRoots) -Name 'evaluatedRoots' -Projection {param($x)Get-BackupRetentionRootSemanticProjection $x}
    Compare-BackupRetentionPathCollection -Expected @($LiveEvaluation.coverageItems) -Actual @($Document.coverageItems) -Name 'coverageItems' -Projection {param($x)Get-BackupRetentionItemSemanticProjection $x}
    foreach($pair in @(
        @{name='candidates';expected=@($LiveEvaluation.candidates)},@{name='retainedItems';expected=@($LiveEvaluation.retainedItems)},
        @{name='protected';expected=@($LiveEvaluation.protected)},@{name='manualReview';expected=@($LiveEvaluation.manualReview)}
    )) { Compare-BackupRetentionPathCollection -Expected $pair.expected -Actual @($Document.($pair.name)) -Name $pair.name -Projection {param($x)Get-BackupRetentionItemSemanticProjection $x} }
    if((ConvertTo-BackupRetentionSemanticJson @($LiveEvaluation.unclassifiedCoverageGaps))-cne(ConvertTo-BackupRetentionSemanticJson @($Document.unclassifiedCoverageGaps))){throw 'unclassifiedCoverageGaps 与现场复算不一致。'}
    if($Document.coverageAccounted-cne$LiveEvaluation.coverageAccounted-or$Document.coverageComplete-cne$LiveEvaluation.coverageComplete){throw 'coverage 状态与现场复算不一致。'}
    return $true
}

function Test-BackupRetentionDryRunDocument {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Document,[Parameter(Mandatory)][psobject]$TrustedPolicyContext)

    $topNames=@('artifactType','schemaVersion','artifactMode','generatedAtLocal','generatedAtUtc','dryRun','readOnly','deleteAllowed','applySupported','executionAllowed','CodexRoot','DDriveRoot','retainCount','policyId','policyVersion','policy','declaredScanRoots','evaluatedRoots','coverageItems','candidates','retainedItems','protected','manualReview','unclassifiedCoverageGaps','coverageAccounted','coverageComplete','coverageNotes','errors','summary','generationId')
    Assert-BackupRetentionExactProperties $Document $topNames 'document'
    Assert-BackupRetentionString $Document.artifactType 'artifactType'; if($Document.artifactType-cne'env-governance.backup-retention-dry-run'){throw 'artifactType 不受支持。'}
    Assert-BackupRetentionInteger $Document.schemaVersion 'schemaVersion';if([int64]$Document.schemaVersion-ne2){throw 'schemaVersion 必须严格等于 2。'}
    foreach($name in @('artifactMode','generatedAtLocal','generatedAtUtc','CodexRoot','DDriveRoot','policyId','generationId')){Assert-BackupRetentionString $Document.$name $name}
    $parsedGenerationId=[guid]::Empty;if(-not[guid]::TryParse($Document.generationId,[ref]$parsedGenerationId)){throw 'generationId 必须是 GUID string。'}
    foreach($name in @('dryRun','readOnly','deleteAllowed','applySupported','executionAllowed','coverageAccounted','coverageComplete')){Assert-BackupRetentionBoolean $Document.$name $name}
    if(-not$Document.dryRun-or-not$Document.readOnly-or$Document.deleteAllowed-or$Document.applySupported-or$Document.executionAllowed){throw 'dry-run 安全标志不受信任。'}
    if(-not$Document.coverageAccounted-or-not$Document.coverageComplete){throw '覆盖不完整，拒绝 apply。'}
    Assert-BackupRetentionInteger $Document.retainCount 'retainCount';Assert-BackupRetentionInteger $Document.policyVersion 'policyVersion'
    foreach($name in @('declaredScanRoots','evaluatedRoots','coverageItems','candidates','retainedItems','protected','manualReview','unclassifiedCoverageGaps','coverageNotes','errors')){Assert-BackupRetentionArray -Value ([object]$Document.PSObject.Properties[$name].Value) -Name $name}
    if(@($Document.unclassifiedCoverageGaps).Count-ne0-or@($Document.errors).Count-ne0){throw 'dry-run 存在 gap 或 error。'}
    Assert-BackupRetentionExactProperties $TrustedPolicyContext @('artifactMode','CodexRoot','DDriveRoot','retainCount','policyId','policyVersion') 'TrustedPolicyContext'
    Assert-BackupRetentionString $TrustedPolicyContext.artifactMode 'TrustedPolicyContext.artifactMode';Assert-BackupRetentionString $TrustedPolicyContext.CodexRoot 'TrustedPolicyContext.CodexRoot';Assert-BackupRetentionString $TrustedPolicyContext.DDriveRoot 'TrustedPolicyContext.DDriveRoot';Assert-BackupRetentionString $TrustedPolicyContext.policyId 'TrustedPolicyContext.policyId'
    Assert-BackupRetentionInteger $TrustedPolicyContext.retainCount 'TrustedPolicyContext.retainCount';Assert-BackupRetentionInteger $TrustedPolicyContext.policyVersion 'TrustedPolicyContext.policyVersion'
    $trusted=New-BackupRetentionPolicyContext -ArtifactMode $TrustedPolicyContext.artifactMode -CodexRoot $TrustedPolicyContext.CodexRoot -DDriveRoot $TrustedPolicyContext.DDriveRoot -RetainCount ([int]$TrustedPolicyContext.retainCount)
    foreach($name in @('artifactMode','CodexRoot','DDriveRoot','retainCount','policyId','policyVersion')){if($Document.$name-cne$trusted.$name){throw "$name 与可信 policy context 不一致。"}}
    $policyNames=@('policyId','policyVersion','summary','protectedRootsCannotBeDeleted','explicitAuthorizationRequired','applyMustRegenerateDryRun','applyMustCheckReparsePoints','applyMustUseAllowlist','strictTimestampRequired','runtimeSharedDirsExcluded','authAutosaveExcludedByDefault')
    Assert-BackupRetentionExactProperties $Document.policy $policyNames 'policy'
    Assert-BackupRetentionString $Document.policy.policyId 'policy.policyId';Assert-BackupRetentionInteger $Document.policy.policyVersion 'policy.policyVersion';Assert-BackupRetentionString $Document.policy.summary 'policy.summary'
    foreach($name in @('protectedRootsCannotBeDeleted','explicitAuthorizationRequired','applyMustRegenerateDryRun','applyMustCheckReparsePoints','applyMustUseAllowlist','strictTimestampRequired','runtimeSharedDirsExcluded','authAutosaveExcludedByDefault')){Assert-BackupRetentionBoolean $Document.policy.$name "policy.$name";if(-not$Document.policy.$name){throw "policy.$name 必须为 true。"}}
    if($Document.policy.policyId-cne$trusted.policyId-or$Document.policy.policyVersion-cne$trusted.policyVersion){throw 'policy 身份不受信任。'}
    foreach($declared in @($Document.declaredScanRoots)){Assert-BackupRetentionExactProperties $declared @('rootId','path','rule') 'declaredScanRoot';foreach($name in @('rootId','path','rule')){Assert-BackupRetentionString $declared.$name "declaredScanRoot.$name"}}
    foreach($root in @($Document.evaluatedRoots)){
        Assert-BackupRetentionExactProperties $root @('rootId','path','rule','metadataStatus','exists','rootIsReparsePoint','reparseAncestor','reparseTarget','enumerationStarted','enumerationCompleted','errors','directChildCount','directChildren','snapshotSha256','classificationCount','classificationCounts') 'evaluatedRoot'
        foreach($name in @('rootId','path','rule','metadataStatus','enumerationStarted','snapshotSha256')){Assert-BackupRetentionString $root.$name "evaluatedRoot.$name"}
        Assert-BackupRetentionNullableBoolean $root.exists 'evaluatedRoot.exists';Assert-BackupRetentionBoolean $root.rootIsReparsePoint 'evaluatedRoot.rootIsReparsePoint';Assert-BackupRetentionBoolean $root.enumerationCompleted 'evaluatedRoot.enumerationCompleted'
        Assert-BackupRetentionNullableString $root.reparseAncestor 'evaluatedRoot.reparseAncestor';Assert-BackupRetentionNullableString $root.reparseTarget 'evaluatedRoot.reparseTarget';Assert-BackupRetentionStringArray ([object]$root.errors) 'evaluatedRoot.errors'
        foreach($name in @('directChildCount','classificationCount')){Assert-BackupRetentionInteger $root.$name "evaluatedRoot.$name"}
        Assert-BackupRetentionArray ([object]$root.directChildren) 'evaluatedRoot.directChildren'
        foreach($child in @($root.directChildren)){Assert-BackupRetentionExactProperties $child @('path','name','itemType','isReparsePoint','reparseTarget') 'directChild';foreach($name in @('path','name','itemType')){Assert-BackupRetentionString $child.$name "directChild.$name"};Assert-BackupRetentionBoolean $child.isReparsePoint 'directChild.isReparsePoint';Assert-BackupRetentionNullableString $child.reparseTarget 'directChild.reparseTarget'}
        Assert-BackupRetentionExactProperties $root.classificationCounts @('candidate','retained','protected','delegated-root','gap') 'evaluatedRoot.classificationCounts';foreach($name in @('candidate','retained','protected','delegated-root','gap')){Assert-BackupRetentionInteger $root.classificationCounts.$name "evaluatedRoot.classificationCounts.$name"}
    }
    foreach($collectionName in @('coverageItems','candidates','retainedItems','protected','manualReview')){foreach($item in @($Document.$collectionName)){Assert-BackupRetentionItemSchema $item "$collectionName[$($item.path)]"}}
    foreach($gap in @($Document.unclassifiedCoverageGaps)){Assert-BackupRetentionExactProperties $gap @('path','scanRoot','reason') 'unclassifiedCoverageGap';Assert-BackupRetentionString $gap.path 'unclassifiedCoverageGap.path';Assert-BackupRetentionNullableString $gap.scanRoot 'unclassifiedCoverageGap.scanRoot';Assert-BackupRetentionString $gap.reason 'unclassifiedCoverageGap.reason'}
    Assert-BackupRetentionStringArray ([object]$Document.coverageNotes) 'coverageNotes';Assert-BackupRetentionStringArray ([object]$Document.errors) 'errors'
    Assert-BackupRetentionSummarySchema $Document.summary 'summary'
    Assert-BackupRetentionUniquePaths @($Document.coverageItems) 'coverageItems';Assert-BackupRetentionUniquePaths @($Document.candidates) 'candidates'
    $live=Invoke-BackupRetentionEvaluation -PolicyContext $trusted
    Compare-BackupRetentionEvaluation -Document $Document -LiveEvaluation $live|Out-Null
    $liveSummary=Get-BackupRetentionEvaluationSummary $live
    if((ConvertTo-BackupRetentionSemanticJson $Document.summary)-cne(ConvertTo-BackupRetentionSemanticJson $liveSummary)){throw 'summary 与现场复算不一致。'}
    return $live
}

function Resolve-BackupRetentionCandidateSelection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Candidates,
        [switch]$UseAllDryRunCandidates,
        [AllowEmptyCollection()][string[]]$AllowPath=@()
    )
    if(-not$UseAllDryRunCandidates-and@($AllowPath).Count-eq0){throw '必须指定 -UseAllDryRunCandidates 或至少一个 -AllowPath。'}
    if($UseAllDryRunCandidates-and@($AllowPath).Count-gt0){throw '-UseAllDryRunCandidates 和 -AllowPath 不能同时使用。'}
    $map=@{};foreach($candidate in $Candidates){$key=(Get-BackupRetentionCanonicalPath $candidate.path).ToLowerInvariant();if($map.ContainsKey($key)){throw "candidate 重复：$($candidate.path)"};$map[$key]=$candidate}
    if($UseAllDryRunCandidates){return [object[]]@($Candidates)}
    $result=[Collections.Generic.List[object]]::new();$seen=@{}
    foreach($allow in $AllowPath){$full=Assert-BackupRetentionDPath -Path $allow -Name 'AllowPath';$key=$full.ToLowerInvariant();if($seen.ContainsKey($key)){throw "AllowPath 重复：$full"};$seen[$key]=$true;if(-not$map.ContainsKey($key)){throw "AllowPath 不在已验证 candidates 中：$full"};$result.Add($map[$key])}
    return [object[]]$result.ToArray()
}

function Assert-BackupRetentionCandidateLiveState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Candidate,[Parameter(Mandatory)][psobject]$TrustedPolicyContext,[Parameter(Mandatory)][psobject]$LiveEvaluation)
    $path=Get-BackupRetentionCanonicalPath $Candidate.path
    $chain=Get-BackupRetentionPathChainState -Path $path -TrustedRoot $TrustedPolicyContext.DDriveRoot
    if($chain.status-cne'ok'-or-not$chain.exists){throw "candidate 当前路径不存在或 reparse metadata 不安全：$path"}
    foreach($item in @($LiveEvaluation.protected)+@($LiveEvaluation.manualReview)){
        if((Test-BackupRetentionPathWithinRoot $path $item.path)-or(Test-BackupRetentionPathWithinRoot $item.path $path)){throw "candidate 与保护/人工审查路径重叠：$path"}
    }
    $current=Get-BackupRetentionSafeStats $path -IncludeTreeDigest
    if($current.reparsePointsSkipped-ne0-or$current.inaccessibleItems-ne0-or$current.treeSha256-notmatch'^[0-9a-f]{64}$'){throw "candidate 当前包含 reparse point、不可访问项或缺少 tree digest：$path"}
    if((ConvertTo-BackupRetentionSemanticJson $Candidate.stats)-cne(ConvertTo-BackupRetentionSemanticJson $current)){throw "candidate 当前 stats 与已验证现场复算不一致：$path"}
    return $current
}

function Read-BackupRetentionApplyGateSource {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DryRunJson,[Parameter(Mandatory)][string]$DryRunMarkdown,[string]$ExpectedSourceSha256='')
    $jsonPath=Assert-BackupRetentionDPath -Path $DryRunJson -Name 'DryRunJson'
    $markdownPath=Assert-BackupRetentionDPath -Path $DryRunMarkdown -Name 'DryRunMarkdown'
    if(-not(Test-Path -LiteralPath $jsonPath -PathType Leaf)){throw "DryRunJson 不存在：$jsonPath"}
    if(-not(Test-Path -LiteralPath $markdownPath -PathType Leaf)){throw "DryRunMarkdown 不存在：$markdownPath"}
    $bytes=[IO.File]::ReadAllBytes($jsonPath)
    $sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    if(-not[string]::IsNullOrWhiteSpace($ExpectedSourceSha256)-and$sha256-cne$ExpectedSourceSha256){throw 'DryRunJson 源 SHA-256 发生漂移。'}
    try{$jsonText=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)}catch{throw "DryRunJson 不是严格 UTF-8：$($_.Exception.Message)"}
    Assert-BackupRetentionStrictJsonText -JsonText $jsonText
    try{$document=$jsonText|ConvertFrom-Json -DateKind String -ErrorAction Stop}catch{throw "DryRunJson 无法转换为对象：$($_.Exception.Message)"}
    $pair=Test-JsonMarkdownArtifactPair -JsonPath $jsonPath -MarkdownPath $markdownPath
    if(-not$pair.ok){throw "DryRunJson 报告对校验失败：$($pair.error)"}
    if($pair.sourceJsonSha256-cne$sha256){throw 'DryRunJson 报告对校验期间 JSON 发生漂移。'}
    if($document.PSObject.Properties.Name-notcontains'generationId'-or$document.generationId-cne$pair.generationId){throw 'DryRunJson 报告对 generationId 不一致。'}
    return [pscustomobject]@{jsonPath=$jsonPath;markdownPath=$markdownPath;sourceJsonSha256=$sha256;document=$document}
}

function Invoke-BackupRetentionApplyFinalGate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$TrustedPolicyContext,
        [Parameter(Mandatory)][string]$DryRunJson,
        [Parameter(Mandatory)][string]$DryRunMarkdown,
        [Parameter(Mandatory)][string]$InitialSourceSha256,
        [Parameter(Mandatory)][string]$OutputDir,
        [switch]$UseAllDryRunCandidates,
        [AllowEmptyCollection()][string[]]$AllowPath=@(),
        [scriptblock]$AfterCandidateCheckHook
    )
    if($InitialSourceSha256-notmatch'^[0-9a-f]{64}$'){throw 'InitialSourceSha256 必须是 lowercase SHA-256。'}
    $initialOutput=Assert-BackupRetentionDPath -Path $OutputDir -Name 'OutputDir'
    $initialSource=Read-BackupRetentionApplyGateSource -DryRunJson $DryRunJson -DryRunMarkdown $DryRunMarkdown -ExpectedSourceSha256 $InitialSourceSha256
    if($initialSource.sourceJsonSha256-cne$InitialSourceSha256){throw 'DryRunJson 初始 SHA-256 已漂移。'}
    $initialLive=Test-BackupRetentionDryRunDocument -Document $initialSource.document -TrustedPolicyContext $TrustedPolicyContext
    $initialSelected=@(Resolve-BackupRetentionCandidateSelection -Candidates @($initialLive.candidates) -UseAllDryRunCandidates:$UseAllDryRunCandidates -AllowPath $AllowPath)
    $initialValidated=[Collections.Generic.List[object]]::new()
    foreach($candidate in $initialSelected){$stats=Assert-BackupRetentionCandidateLiveState -Candidate $candidate -TrustedPolicyContext $TrustedPolicyContext -LiveEvaluation $initialLive;$initialValidated.Add([pscustomobject]@{candidate=$candidate;currentStats=$stats})}

    if($null-eq$AfterCandidateCheckHook){
        return [pscustomobject]@{sourceDocument=$initialSource.document;sourceJsonSha256=$initialSource.sourceJsonSha256;liveEvaluation=$initialLive;selectedCandidates=[object[]]$initialSelected;validatedCandidates=[object[]]$initialValidated.ToArray();outputDir=$initialOutput}
    }

    & $AfterCandidateCheckHook ([pscustomobject]@{dryRunJson=$initialSource.jsonPath;dryRunMarkdown=$initialSource.markdownPath;outputDir=$initialOutput;liveEvaluation=$initialLive;selectedCandidates=[object[]]$initialSelected})|Out-Null

    $finalOutput=Assert-BackupRetentionDPath -Path $initialOutput -Name 'OutputDir'
    $finalSource=Read-BackupRetentionApplyGateSource -DryRunJson $initialSource.jsonPath -DryRunMarkdown $initialSource.markdownPath -ExpectedSourceSha256 $InitialSourceSha256
    if($finalSource.sourceJsonSha256-cne$InitialSourceSha256){throw 'DryRunJson 在二次校验后发生 SHA-256 漂移。'}
    $finalLive=Test-BackupRetentionDryRunDocument -Document $finalSource.document -TrustedPolicyContext $TrustedPolicyContext
    $finalSelected=@(Resolve-BackupRetentionCandidateSelection -Candidates @($finalLive.candidates) -UseAllDryRunCandidates:$UseAllDryRunCandidates -AllowPath $AllowPath)
    $initialKeys=@($initialSelected|ForEach-Object{(Get-BackupRetentionCanonicalPath $_.path).ToLowerInvariant()}|Sort-Object)
    $finalKeys=@($finalSelected|ForEach-Object{(Get-BackupRetentionCanonicalPath $_.path).ToLowerInvariant()}|Sort-Object)
    if($initialKeys.Count-ne$finalKeys.Count-or(Compare-Object -ReferenceObject $initialKeys -DifferenceObject $finalKeys).Count-ne0){throw 'candidate selection 在最终 gate 发生漂移。'}
    $validated=[Collections.Generic.List[object]]::new()
    foreach($candidate in $finalSelected){$stats=Assert-BackupRetentionCandidateLiveState -Candidate $candidate -TrustedPolicyContext $TrustedPolicyContext -LiveEvaluation $finalLive;$validated.Add([pscustomobject]@{candidate=$candidate;currentStats=$stats})}
    return [pscustomobject]@{sourceDocument=$finalSource.document;sourceJsonSha256=$finalSource.sourceJsonSha256;liveEvaluation=$finalLive;selectedCandidates=[object[]]$finalSelected;validatedCandidates=[object[]]$validated.ToArray();outputDir=$finalOutput}
}
