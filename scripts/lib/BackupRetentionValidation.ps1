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
function Get-BackupRetentionValidationPathKey { param([object]$Value,[string]$Name) Assert-BackupRetentionString $Value $Name; return (Get-BackupRetentionCanonicalPath -Path $Value).ToLowerInvariant() }
function ConvertTo-BackupRetentionSemanticJson { param([object]$Value) return (ConvertTo-Json -InputObject $Value -Depth 100 -Compress) }

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

    foreach($name in @('artifactType','schemaVersion','artifactMode','generatedAtUtc','dryRun','readOnly','deleteAllowed','applySupported','executionAllowed','CodexRoot','DDriveRoot','retainCount','policyId','policyVersion','policy','declaredScanRoots','evaluatedRoots','coverageItems','candidates','retainedItems','protected','manualReview','unclassifiedCoverageGaps','coverageAccounted','coverageComplete','coverageNotes','errors','summary')){Assert-BackupRetentionProperty $Document $name|Out-Null}
    Assert-BackupRetentionString $Document.artifactType 'artifactType'; if($Document.artifactType-cne'env-governance.backup-retention-dry-run'){throw 'artifactType 不受支持。'}
    Assert-BackupRetentionInteger $Document.schemaVersion 'schemaVersion';if([int64]$Document.schemaVersion-ne2){throw 'schemaVersion 必须严格等于 2。'}
    foreach($name in @('artifactMode','generatedAtUtc','CodexRoot','DDriveRoot','policyId')){Assert-BackupRetentionString $Document.$name $name}
    foreach($name in @('dryRun','readOnly','deleteAllowed','applySupported','executionAllowed','coverageAccounted','coverageComplete')){Assert-BackupRetentionBoolean $Document.$name $name}
    if(-not$Document.dryRun-or-not$Document.readOnly-or$Document.deleteAllowed-or$Document.applySupported-or$Document.executionAllowed){throw 'dry-run 安全标志不受信任。'}
    if(-not$Document.coverageAccounted-or-not$Document.coverageComplete){throw '覆盖不完整，拒绝 apply。'}
    Assert-BackupRetentionInteger $Document.retainCount 'retainCount';Assert-BackupRetentionInteger $Document.policyVersion 'policyVersion'
    foreach($name in @('declaredScanRoots','evaluatedRoots','coverageItems','candidates','retainedItems','protected','manualReview','unclassifiedCoverageGaps','coverageNotes','errors')){Assert-BackupRetentionArray -Value ([object]$Document.PSObject.Properties[$name].Value) -Name $name}
    if(@($Document.unclassifiedCoverageGaps).Count-ne0-or@($Document.errors).Count-ne0){throw 'dry-run 存在 gap 或 error。'}
    foreach($name in @('artifactMode','CodexRoot','DDriveRoot','retainCount','policyId','policyVersion')){Assert-BackupRetentionProperty $TrustedPolicyContext $name 'TrustedPolicyContext'|Out-Null}
    Assert-BackupRetentionString $TrustedPolicyContext.artifactMode 'TrustedPolicyContext.artifactMode';Assert-BackupRetentionString $TrustedPolicyContext.CodexRoot 'TrustedPolicyContext.CodexRoot';Assert-BackupRetentionString $TrustedPolicyContext.DDriveRoot 'TrustedPolicyContext.DDriveRoot';Assert-BackupRetentionString $TrustedPolicyContext.policyId 'TrustedPolicyContext.policyId'
    Assert-BackupRetentionInteger $TrustedPolicyContext.retainCount 'TrustedPolicyContext.retainCount';Assert-BackupRetentionInteger $TrustedPolicyContext.policyVersion 'TrustedPolicyContext.policyVersion'
    $trusted=New-BackupRetentionPolicyContext -ArtifactMode $TrustedPolicyContext.artifactMode -CodexRoot $TrustedPolicyContext.CodexRoot -DDriveRoot $TrustedPolicyContext.DDriveRoot -RetainCount ([int]$TrustedPolicyContext.retainCount)
    foreach($name in @('artifactMode','CodexRoot','DDriveRoot','retainCount','policyId','policyVersion')){if($Document.$name-cne$trusted.$name){throw "$name 与可信 policy context 不一致。"}}
    foreach($name in @('policyId','policyVersion','applyMustUseAllowlist','applyMustCheckReparsePoints')){Assert-BackupRetentionProperty $Document.policy $name 'policy'|Out-Null}
    Assert-BackupRetentionString $Document.policy.policyId 'policy.policyId';Assert-BackupRetentionInteger $Document.policy.policyVersion 'policy.policyVersion';Assert-BackupRetentionBoolean $Document.policy.applyMustUseAllowlist 'policy.applyMustUseAllowlist';Assert-BackupRetentionBoolean $Document.policy.applyMustCheckReparsePoints 'policy.applyMustCheckReparsePoints'
    if($Document.policy.policyId-cne$trusted.policyId-or$Document.policy.policyVersion-cne$trusted.policyVersion-or-not$Document.policy.applyMustUseAllowlist-or-not$Document.policy.applyMustCheckReparsePoints){throw 'policy 安全属性不受信任。'}
    foreach($root in @($Document.evaluatedRoots)){
        foreach($name in @('exists','rootIsReparsePoint','enumerationCompleted')){Assert-BackupRetentionBoolean (Assert-BackupRetentionProperty $root $name 'evaluatedRoot') "evaluatedRoot.$name"}
        foreach($name in @('errors','directChildren')){Assert-BackupRetentionProperty $root $name 'evaluatedRoot'|Out-Null;Assert-BackupRetentionArray -Value ([object]$root.PSObject.Properties[$name].Value) -Name "evaluatedRoot.$name"}
        foreach($name in @('directChildCount','classificationCount')){Assert-BackupRetentionInteger (Assert-BackupRetentionProperty $root $name 'evaluatedRoot') "evaluatedRoot.$name"}
    }
    foreach($item in @($Document.coverageItems)){
        foreach($name in @('coverageAccounted','requiresManualReview','blocksCoverage','automaticCandidate','selectedByRetention','applyEligible','requiresExplicitAuthorization')){Assert-BackupRetentionBoolean (Assert-BackupRetentionProperty $item $name 'coverageItem') "coverageItem.$name"}
        foreach($name in @('errors','blockedBy')){Assert-BackupRetentionProperty $item $name 'coverageItem'|Out-Null;Assert-BackupRetentionArray -Value ([object]$item.PSObject.Properties[$name].Value) -Name "coverageItem.$name"}
    }
    Assert-BackupRetentionUniquePaths @($Document.coverageItems) 'coverageItems';Assert-BackupRetentionUniquePaths @($Document.candidates) 'candidates'
    $live=Invoke-BackupRetentionEvaluation -PolicyContext $trusted
    Compare-BackupRetentionEvaluation -Document $Document -LiveEvaluation $live|Out-Null
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
    $current=Get-BackupRetentionSafeStats $path
    if($current.reparsePointsSkipped-ne0-or$current.inaccessibleItems-ne0){throw "candidate 当前包含 reparse point 或不可访问项：$path"}
    if((ConvertTo-BackupRetentionSemanticJson $Candidate.stats)-cne(ConvertTo-BackupRetentionSemanticJson $current)){throw "candidate 当前 stats 与已验证现场复算不一致：$path"}
    return $current
}
