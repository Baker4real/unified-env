param([string]$OutputName='comparison-n1.json')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo='D:/agents/projects/统一环境'
$frozen='88d4b67943d7d451931c024ad031a591efcffd528df9acbcb5e0d566d5938ad6'
function ReadJson([string]$name){
    $path=Join-Path $PSScriptRoot $name
    $text=if($name.EndsWith('/stdout.json')){
        [Text.Encoding]::GetEncoding(936,[Text.EncoderFallback]::ExceptionFallback,[Text.DecoderFallback]::ExceptionFallback).GetString([IO.File]::ReadAllBytes($path))
    }else{[IO.File]::ReadAllText($path)}
    ConvertFrom-Json $text -AsHashtable -Depth 128 -DateKind String
}
function Sha([string]$text){[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text))).ToLowerInvariant()}
function All([Collections.IDictionary]$checks){@($checks.Values|Where-Object{$_ -isnot [bool] -or -not $_}).Count -eq 0}
function EqualFields($a,$b){
    $c=[ordered]@{}
    foreach($key in $a.Keys){$c[$key]=$b.Contains($key) -and (ConvertTo-Json -InputObject $a[$key] -Depth 20 -Compress) -ceq (ConvertTo-Json -InputObject $b[$key] -Depth 20 -Compress)}
    $c.sameFieldSet=(($a.Keys|Sort-Object)-join '|') -ceq (($b.Keys|Sort-Object)-join '|')
    $c
}
function Coverage([object[]]$operations){
    $ids=[Collections.Generic.List[string]]::new();$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $invalid=0;$duplicates=0
    foreach($op in $operations){
        $id=$op['operationId']
        if($id -isnot [string] -or [string]::IsNullOrWhiteSpace($id)){$invalid++;continue}
        if(-not $seen.Add($id)){$duplicates++};$ids.Add($id)
    }
    $ids.Sort([StringComparer]::Ordinal)
    @{count=$operations.Count;invalidIds=$invalid;duplicates=$duplicates;idDigest=(Sha (ConvertTo-Json -InputObject $ids.ToArray() -Compress))}
}
function RunChecks($r,$coverage,$count,$digest){
    [ordered]@{
        errorNull=$r.Contains('error') -and $null -eq $r.error
        childExitZero=$null -ne $r.exitCode -and $r.exitCode -eq 0
        parsed=$r.parseSucceeded -is [bool] -and $r.parseSucceeded
        notTimedOut=$r.timedOut -is [bool] -and -not $r.timedOut
        beforeDeadline=$r.completedBeforeDeadline -is [bool] -and $r.completedBeforeDeadline
        completeMatchesFrozen=$r.complete -is [bool] -and $r.complete -eq $false
        below60000=$null -ne $r.elapsedMs -and $r.elapsedMs -ge 0 -and $r.elapsedMs -lt 60000
        semantic=$r.semanticSha256 -ceq $frozen
        validUniqueIds=$coverage.invalidIds -eq 0 -and $coverage.duplicates -eq 0
        fullIdSet=$count -gt 0 -and $coverage.count -eq $count -and $coverage.idDigest -ceq $digest
    }
}
$summary=[ordered]@{status='DONE_WITH_CONCERNS';aggregateExitCode=1;errors=@();checks=[ordered]@{};fingerprints=@{};source=@{};negativeControls=@{};rawExitCodes=@{};run=$null;diagnostic=$null;observation=$null;pidClosure=@();validation=@{};files=@();transport=@{rawStdoutCodePage=936;rawBytesPreserved=$true;limitation='本轮管道原字节为 CP936；聚合严格解码并验证字节回环，不按 UTF-8 替换字符计算语义。'};scope='N1 默认配置单次归因，不是正式三冷或宿主 gate 验收；只比较冻结管线，已知 23-op 分叉未改。'}
try{
    $execution=ReadJson 'execution-n1.json';$summary.rawExitCodes=$execution.rawExitCodes;$summary.observation=$execution.observation
    $summary.checks.executionErrorNull=$null -eq $execution.error
    $summary.checks.environmentDefault=@($execution.environment|Where-Object{-not $_.default}).Count -eq 0 -and $execution.environment.Count -eq 9
    $summary.checks.observationValid=$execution.observation.valid
    $summary.checks.observedNoChanges=$execution.observation.valid -and $execution.observation.events -eq 0
    $summary.observation.claim=if($summary.checks.observedNoChanges){'限定范围和窗口内未观测到变更（observed no changes），不是绝对零写保证。'}else{'观测存在事件或覆盖不可用，不得声称窗口内未观测到变更。'}
    foreach($row in $execution.source){$summary.source[$row.path]=(Get-FileHash -LiteralPath (Join-Path $repo $row.path)).Hash.ToLowerInvariant() -ceq $row.sha256}
    $binding=ReadJson 'preflight-bindings-v2.json'
    foreach($row in $binding.files){$summary.source[$row.name]=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $row.name)).Hash.ToLowerInvariant() -ceq $row.sha256}
    $summary.checks.executedSourceBound=All $summary.source
}catch{$summary.errors+=('执行/绑定: '+$_.Exception.Message)}
try{
    $before=ReadJson 'fingerprint-before/stdout.json';$after=ReadJson 'fingerprint-after/stdout.json'
    foreach($section in @('evidence','policy')){$summary.fingerprints[$section]=EqualFields $before[$section] $after[$section]}
    $summary.checks.evidenceContentIdentityUnchanged=All $summary.fingerprints.evidence
    $summary.checks.policyContentIdentityUnchanged=All $summary.fingerprints.policy
    $summary.expected=@{count=$before.evidence.operationCount;idDigest=$before.evidence.operationIdsSha256;semanticSha256=$frozen;complete=$false}
    $r=ReadJson 'n1-default/result.json';$parsed=ReadJson 'n1-default/stdout.json'
    $raw=[IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'n1-default/stdout.json'))
    $encoding=[Text.Encoding]::GetEncoding(936,[Text.EncoderFallback]::ExceptionFallback,[Text.DecoderFallback]::ExceptionFallback)
    $summary.transport.roundTripBytesEqual=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($raw)) -ceq [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($encoding.GetBytes($encoding.GetString($raw))))
    $coverage=Coverage $parsed.operations
    $segments=$parsed.statusSegments
    foreach($name in @('capturedAtUtc','metrics','statusSegments')){[void]$parsed.Remove($name)}
    $r.semanticSha256=Sha (ConvertTo-Json -InputObject $parsed -Depth 100 -Compress)
    $checks=RunChecks $r $coverage $before.evidence.operationCount $before.evidence.operationIdsSha256
    $checks.schema=$parsed.artifactType -ceq 'env-governance.codex-safe-tree-delete-status' -and $parsed.schemaVersion -eq 1 -and $parsed.operations -is [array]
    $checks.stdoutComplete=$parsed.complete -is [bool] -and $parsed.complete -eq $false
    $checks.osIdentity=$r.identityVerified -and $r.osObservation -ceq 'verified' -and $r.childReceipt.version -ceq '7.6.5'
    $checks.wrapperExitZero=$r.wrapperExitCode -eq 0 -and $summary.rawExitCodes.diagnostic -eq 0
    $checks.jobEmpty=$r.jobEmpty -and $r.residualPids.Count -eq 0 -and $r.unverifiedMembers.Count -eq 0
    $summary.run=@{elapsedMs=$r.elapsedMs;timedOut=$r.timedOut;exitCode=$r.exitCode;wrapperExitCode=$r.wrapperExitCode;processId=$r.processId;parseSucceeded=$r.parseSucceeded;complete=$r.complete;operationCount=$r.operationCount;semanticSha256=$r.semanticSha256;coverage=$coverage;checks=$checks;failedChecks=@($checks.Keys|Where-Object{-not $checks[$_]})}
    $summary.checks.runPassed=All $checks
    $historical=ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $repo 'reports/issue58-20260908/live-rerun-20260909/cold-run-1-stdout.json'))) -AsHashtable -Depth 128 -DateKind String
    $oldMap=@{};foreach($op in $historical.operations){$oldMap[$op.operationId]=$op}
    $summary.frozenDifferences=@(foreach($op in $parsed.operations){
        $old=$oldMap[$op.operationId]
        $fields=@(foreach($key in $op.Keys){if((ConvertTo-Json -InputObject $op[$key] -Depth 30 -Compress) -cne (ConvertTo-Json -InputObject $old[$key] -Depth 30 -Compress)){$key}})
        if($fields.Count){@{operationId=$op.operationId;fields=$fields;oldTargetEntryType=$old.targetEntryType;newTargetEntryType=$op.targetEntryType;note='现场 namespace 观测差异，不豁免冻结语义失败；未改此目标。'}}
    })
    $summary.diagnostic=ReadJson 'n1-default/diagnostic.json'
    $timings=@{}
    foreach($line in $segments.debugOpTimings){$parts=$line.Split('|');$timings[[int]$parts[0]]=[long]$parts[2]}
    $groupRows=@();$workerTotals=@{}
    foreach($group in $segments.debugFallbackGroups){
        $total=0L
        foreach($index in $group.indices){if(-not $timings.ContainsKey([int]$index)){throw '组映射中的 operation 缺少计时'};$total+=$timings[[int]$index]}
        $groupRows+=@{group=$group.group;worker=$group.worker;count=$group.indices.Count;serialOperationMs=$total}
        $key=[string]$group.worker;if(-not $workerTotals.ContainsKey($key)){$workerTotals[$key]=0L};$workerTotals[$key]+=$total
    }
    $summary.diagnostic.groupCount=$groupRows.Count;$summary.diagnostic.groupMappingMs=$segments.debugGroupMappingMs
    $summary.diagnostic.workerSerialOperationMs=$workerTotals
    $summary.diagnostic.topGroups=@($groupRows|Sort-Object serialOperationMs -Descending|Select-Object -First 5)
    [void]$segments.Remove('debugOpTimings');[void]$segments.Remove('debugFallbackGroups')
    $summary.diagnostic.segments=$segments
    $summary.diagnostic.timingBoundary='每组及 worker 的操作墙钟只在自身串行序列内相加；不同 worker 和 leaf 累计不相加为整体墙钟。'
}catch{$summary.errors+=('指纹/采样: '+$_.Exception.Message)}
try{
    $fixture=@{error=$null;exitCode=0;parseSucceeded=$true;timedOut=$false;completedBeforeDeadline=$true;complete=$false;elapsedMs=1;semanticSha256=$frozen}
    $cov=Coverage @(@{operationId='a'},@{operationId='b'})
    $summary.negativeControls.falseCompleteAccepted=All (RunChecks $fixture $cov 2 $cov.idDigest)
    foreach($mutation in @(@{key='error';value='fixture'},@{key='exitCode';value=$null},@{key='exitCode';value=1},@{key='parseSucceeded';value=$false},@{key='timedOut';value=$true},@{key='completedBeforeDeadline';value=$false},@{key='complete';value=$true},@{key='complete';value='false'},@{key='elapsedMs';value=60000},@{key='elapsedMs';value=$null},@{key='semanticSha256';value='bad'})){
        $bad=$fixture.Clone();$bad[$mutation.key]=$mutation.value
        $summary.negativeControls[($mutation.key+'-'+[string]$mutation.value+'-rejected')]=-not (All (RunChecks $bad $cov 2 $cov.idDigest))
    }
    foreach($case in @(@{name='duplicate';ops=@(@{operationId='a'},@{operationId='a'})},@{name='emptyId';ops=@(@{operationId=''},@{operationId='b'})},@{name='wrongSetSameCount';ops=@(@{operationId='a'},@{operationId='c'})},@{name='emptySet';ops=@()})){
        $summary.negativeControls[$case.name]=-not (All (RunChecks $fixture (Coverage $case.ops) 2 $cov.idDigest))
    }
    $summary.checks.aggregateNegativeControls=All $summary.negativeControls
    $summary.checks.syntheticChecks=(ReadJson 'synthetic-checks-v2.json').passed
    $summary.checks.diagnosticEnabledCheck=(ReadJson 'diagnostics-check-True.json').passed
    $summary.checks.diagnosticDisabledCheck=(ReadJson 'diagnostics-check-False.json').passed
}catch{$summary.errors+=('负例: '+$_.Exception.Message)}
try{
    foreach($name in @('fingerprint-before','n1-default','fingerprint-after')){
        $r=ReadJson "$name/result.json"
        $p=Get-Process -Id $r.processId -ErrorAction SilentlyContinue
        $same=$null -ne $p -and $p.StartTime.ToUniversalTime() -eq [datetimeoffset]::Parse($r.osStartTimeUtc).UtcDateTime
        $summary.pidClosure+=@{name=$name;processId=$r.processId;recordedJobEmpty=$r.jobEmpty;sameProcessPresent=$same;rawChildExit=$r.exitCode;rawWrapperExit=$r.wrapperExitCode;residualPids=$r.residualPids}
    }
    $summary.checks.pidClosure=@($summary.pidClosure|Where-Object{$_.sameProcessPresent -or -not $_.recordedJobEmpty -or $_.residualPids.Count}).Count -eq 0
    $summary.checks.allRawCommandsZero=@($summary.pidClosure|Where-Object{$null -eq $_.rawChildExit -or $_.rawChildExit -ne 0 -or $_.rawWrapperExit -ne 0}).Count -eq 0
    & (Join-Path $PSScriptRoot 'capture-state.ps1') -Label after
    $stateBefore=ReadJson 'before-state.json';$stateAfter=ReadJson 'after-state.json'
    $summary.checks.headUnchanged=$stateBefore.head -ceq $stateAfter.head
    $summary.checks.shimUnchanged=$stateBefore.shimSha256 -ceq $stateAfter.shimSha256
    $oldChecks=@($stateBefore.oldEvidenceFiles|ForEach-Object{$old=$_;$now=@($stateAfter.oldEvidenceFiles|Where-Object{$_.name -ceq $old.name});$now.Count -eq 1 -and $now[0].sha256 -ceq $old.sha256 -and $now[0].length -eq $old.length})
    $summary.checks.old28EvidenceFilesUnchanged=$oldChecks.Count -eq 28 -and $stateAfter.oldEvidenceFiles.Count -eq 28 -and @($oldChecks|Where-Object{-not $_}).Count -eq 0
}catch{$summary.errors+=('收口/前后态: '+$_.Exception.Message)}
$parseErrors=@()
foreach($path in @((Join-Path $repo 'scripts/lib/CodexSafeTreeDelete.ps1'))+@(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File|ForEach-Object{$_.FullName})){
    $tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    $parseErrors+=@($errors|ForEach-Object{$_.Message})
}
$summary.validation.psSyntax=@{exitCode=$(if($parseErrors.Count){1}else{0});errors=$parseErrors}
& node (Join-Path $repo 'scripts/Validate-ModuleBoundaries.cjs') *> (Join-Path $PSScriptRoot 'module-boundaries.txt')
$summary.validation.moduleBoundaries=@{exitCode=$LASTEXITCODE}
& git --no-optional-locks -C $repo diff --check *> (Join-Path $PSScriptRoot 'git-diff-check.txt')
$summary.validation.gitDiffCheck=@{exitCode=$LASTEXITCODE}
$summary.checks.validationPassed=@($summary.validation.Values|Where-Object{$_.exitCode -ne 0}).Count -eq 0
$summary.checks.noAggregationErrors=$summary.errors.Count -eq 0
$summary.failedChecks=@($summary.checks.Keys|Where-Object{-not $summary.checks[$_]})
if(All $summary.checks){$summary.status='DONE';$summary.aggregateExitCode=0}
$summary.files=@(Get-ChildItem -LiteralPath $PSScriptRoot -File -Recurse|ForEach-Object{[IO.Path]::GetRelativePath($PSScriptRoot,$_.FullName)})+@($OutputName)
$stream=[IO.File]::Open((Join-Path $PSScriptRoot $OutputName),[IO.FileMode]::CreateNew)
try{$stream.Write([Text.Encoding]::UTF8.GetBytes(($summary|ConvertTo-Json -Depth 24)))}finally{$stream.Dispose()}
Write-Output "N1 聚合: exit=$($summary.aggregateExitCode); failed=$($summary.failedChecks -join ','); errors=$($summary.errors.Count)"
exit $summary.aggregateExitCode
