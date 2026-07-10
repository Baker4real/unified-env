$ErrorActionPreference = 'Stop'

function Assert-True { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw $Message } }
function Assert-Rejected {
    param([scriptblock]$Action,[string]$Label)
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-True $rejected "$Label 必须失败关闭"
}
function Assert-CanRemoveFixture { param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path); $reports = [IO.Path]::GetFullPath((Join-Path $projectRoot 'reports'))
    Assert-True ($full.StartsWith("$($reports.TrimEnd('\'))\",[StringComparison]::OrdinalIgnoreCase)) 'fixture 必须位于 reports 子树'
    $current=$full
    while ($current.StartsWith($reports,[StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $current) { Assert-True (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'fixture 父链不得有 reparse point' }
        if ($current -ieq $reports) { break }; $current=[IO.Directory]::GetParent($current).FullName
    }
}
function New-TestDocument { param($Context,$Evaluation)
    $candidateBytes=[int64](($Evaluation.candidates|ForEach-Object { if ($null-ne$_.stats){[int64]$_.stats.bytes}else{0}}|Measure-Object -Sum).Sum)
    $generatedAt=[datetimeoffset]::Now
    $doc=[pscustomobject][ordered]@{
        artifactType='env-governance.backup-retention-dry-run'; schemaVersion=2; artifactMode=$Context.artifactMode
        generatedAtLocal=$generatedAt.ToString('o',[Globalization.CultureInfo]::InvariantCulture); generatedAtUtc=$generatedAt.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        dryRun=$true; readOnly=$true; deleteAllowed=$false; applySupported=$false; executionAllowed=$false
        CodexRoot=$Context.CodexRoot; DDriveRoot=$Context.DDriveRoot; retainCount=$Context.retainCount; policyId=$Context.policyId; policyVersion=$Context.policyVersion
        policy=Get-BackupRetentionPolicyDocument -PolicyContext $Context
        declaredScanRoots=[object[]]$Evaluation.declaredScanRoots; evaluatedRoots=[object[]]$Evaluation.evaluatedRoots; coverageItems=[object[]]$Evaluation.coverageItems
        candidates=[object[]]$Evaluation.candidates; retainedItems=[object[]]$Evaluation.retainedItems; protected=[object[]]$Evaluation.protected; manualReview=[object[]]$Evaluation.manualReview
        unclassifiedCoverageGaps=[object[]]$Evaluation.unclassifiedCoverageGaps; coverageAccounted=[bool]$Evaluation.coverageAccounted; coverageComplete=[bool]$Evaluation.coverageComplete
        coverageNotes=[object[]]$Evaluation.coverageNotes; errors=[object[]]$Evaluation.errors
        summary=Get-BackupRetentionEvaluationSummary $Evaluation
        generationId=[guid]::NewGuid().ToString()
    }
    return ($doc|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String)
}
function Copy-Document { param($Document) return ($Document|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String) }

$projectRoot=Split-Path -Parent $PSScriptRoot
$fixtureRoot=Join-Path $projectRoot 'reports\backup-retention-validation-test'
Assert-CanRemoveFixture $fixtureRoot
if(Test-Path -LiteralPath $fixtureRoot){Remove-Item -LiteralPath $fixtureRoot -Recurse -Force}
try {
    . (Join-Path $projectRoot 'scripts\lib\BackupRetentionPolicy.ps1')
    . (Join-Path $projectRoot 'scripts\lib\BackupRetentionValidation.ps1')
    . (Join-Path $projectRoot 'scripts\lib\ReportArtifactPublisher.ps1')
    $codexRoot=Join-Path $fixtureRoot '.codex'; $provider=Join-Path $codexRoot 'backups_state\provider-sync'
    New-Item -ItemType Directory -Force -Path $provider|Out-Null
    foreach($name in @('20260701T000006Z','20260701T000005Z','20260701T000004Z','20260701T000003Z','20260701T000002Z','20260701T000001Z')){New-Item -ItemType Directory -Path (Join-Path $provider $name)|Out-Null}
    $candidateContentPath=Join-Path $provider '20260701T000001Z\state.bin';[IO.File]::WriteAllText($candidateContentPath,'AAAA',[Text.UTF8Encoding]::new($false));$candidateContentMtime=[datetime]::SpecifyKind([datetime]'2026-07-01T00:00:00',[DateTimeKind]::Utc);[IO.File]::SetLastWriteTimeUtc($candidateContentPath,$candidateContentMtime)
    $context=New-BackupRetentionPolicyContext -ArtifactMode test -CodexRoot $codexRoot -DDriveRoot $fixtureRoot
    $evaluation=Invoke-BackupRetentionEvaluation -PolicyContext $context
    Assert-True $evaluation.coverageComplete '可信 fixture 必须 coverageComplete=true'
    $document=New-TestDocument $context $evaluation
    $validated=Test-BackupRetentionDryRunDocument -Document $document -TrustedPolicyContext $context
    Assert-True (@($validated.candidates).Count -eq 1) '纯验证器应返回现场复算结果'

    $sourcePairDir=Join-Path $fixtureRoot 'trusted-source-pair';$published=Publish-JsonMarkdownArtifactPair -Document $document -OutputDir $sourcePairDir -JsonFileName 'backup-retention-dry-run.json' -MarkdownFileName 'BACKUP-RETENTION-DRY-RUN.md' -RenderMarkdown { 'fixture' }
    Assert-True ($null-ne(Get-Command Invoke-BackupRetentionApplyFinalGate -ErrorAction SilentlyContinue)) '缺少 Invoke-BackupRetentionApplyFinalGate'
    $sourceDocument=Get-Content -Raw -LiteralPath $published.jsonPath|ConvertFrom-Json -DateKind String
    $initialSourceSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($published.jsonPath))).ToLowerInvariant()
    $finalOutput=Join-Path $fixtureRoot 'manifest-output';New-Item -ItemType Directory -Path $finalOutput|Out-Null
    $oldManifestJson=Join-Path $finalOutput 'backup-retention-apply-manifest.json';$oldManifestMarkdown=Join-Path $finalOutput 'BACKUP-RETENTION-APPLY-MANIFEST.md'
    [IO.File]::WriteAllText($oldManifestJson,'old-json',[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($oldManifestMarkdown,'old-markdown',[Text.UTF8Encoding]::new($false))
    $noHookFinal=Invoke-BackupRetentionApplyFinalGate -TrustedPolicyContext $context -DryRunJson $published.jsonPath -DryRunMarkdown $published.markdownPath -InitialSourceSha256 $initialSourceSha -OutputDir $finalOutput -UseAllDryRunCandidates
    Assert-True(@($noHookFinal.validatedCandidates).Count-eq1-and$noHookFinal.validatedCandidates[0].currentStats.treeSha256-match'^[0-9a-f]{64}$'-and$noHookFinal.finalAgeHours-ge0-and$noHookFinal.validatedAtUtc-is[string])'无 hook 正式路径必须执行一次完整 gate 并返回最终 freshness/tree digest'

    $generatedAt=[datetimeoffset]::Parse($sourceDocument.generatedAtUtc,[Globalization.CultureInfo]::InvariantCulture)
    $script:crossBoundaryClockCalls=0
    $crossBoundaryClock={
        $script:crossBoundaryClockCalls++
        if($script:crossBoundaryClockCalls-eq1){return $script:generatedAt.AddHours(24).AddMinutes(-1)}
        return $script:generatedAt.AddHours(24).AddSeconds(1)
    }
    $message=$null;try{Invoke-BackupRetentionApplyFinalGate -TrustedPolicyContext $context -DryRunJson $published.jsonPath -DryRunMarkdown $published.markdownPath -InitialSourceSha256 $initialSourceSha -OutputDir $finalOutput -UseAllDryRunCandidates -AfterCandidateCheckHook {param($phase)} -NowProvider $crossBoundaryClock|Out-Null}catch{$message=$_.Exception.Message}
    Assert-True($script:crossBoundaryClockCalls-eq2-and$message-like'*已超过*')'临界前开始、hook 后跨过 24h 必须由最终 freshness 拒绝'
    Assert-True(([IO.File]::ReadAllText($oldManifestJson))-ceq'old-json'-and([IO.File]::ReadAllText($oldManifestMarkdown))-ceq'old-markdown')'freshness 跨界不得覆盖旧 manifest pair'

    $rollbackClock={return $script:generatedAt.AddSeconds(-1)};$message=$null
    try{Invoke-BackupRetentionApplyFinalGate -TrustedPolicyContext $context -DryRunJson $published.jsonPath -DryRunMarkdown $published.markdownPath -InitialSourceSha256 $initialSourceSha -OutputDir $finalOutput -UseAllDryRunCandidates -NowProvider $rollbackClock|Out-Null}catch{$message=$_.Exception.Message}
    Assert-True($message-like'*来自未来*')'时钟回拨到 generatedAt 之前必须由最终 freshness 拒绝'
    Assert-True(([IO.File]::ReadAllText($oldManifestJson))-ceq'old-json'-and([IO.File]::ReadAllText($oldManifestMarkdown))-ceq'old-markdown')'时钟回拨不得覆盖旧 manifest pair'
    $runFinalHookCase={param([scriptblock]$Hook,[string]$Label)
        $message=$null;try{Invoke-BackupRetentionApplyFinalGate -TrustedPolicyContext $context -DryRunJson $published.jsonPath -DryRunMarkdown $published.markdownPath -InitialSourceSha256 $initialSourceSha -OutputDir $finalOutput -UseAllDryRunCandidates -AfterCandidateCheckHook $Hook|Out-Null}catch{$message=$_.Exception.Message}
        Assert-True(-not[string]::IsNullOrWhiteSpace($message))"$Label 必须在最终 gate 失败关闭"
        Assert-True(([IO.File]::ReadAllText($oldManifestJson))-ceq'old-json')"$Label 不得覆盖旧 manifest JSON"
        Assert-True(([IO.File]::ReadAllText($oldManifestMarkdown))-ceq'old-markdown')"$Label 不得覆盖旧 manifest Markdown"
    }
    try {
        & $runFinalHookCase {param($phase)[IO.File]::WriteAllText($script:candidateContentPath,'EVIL',[Text.UTF8Encoding]::new($false));[IO.File]::SetLastWriteTimeUtc($script:candidateContentPath,$script:candidateContentMtime);[pscustomobject]@{skipValidation=$true}} 'final gate candidate 同尺寸同mtime内容漂移且 hook 请求 skip'
    } finally {[IO.File]::WriteAllText($candidateContentPath,'AAAA',[Text.UTF8Encoding]::new($false));[IO.File]::SetLastWriteTimeUtc($candidateContentPath,$candidateContentMtime)}

    try{&$runFinalHookCase {param($phase)Set-Content -LiteralPath "${script:candidateContentPath}:audit" -Value 'named-stream' -NoNewline} 'hook 后 candidate 新增 ADS'}finally{Remove-Item -LiteralPath $candidateContentPath -Stream 'audit' -Force -ErrorAction SilentlyContinue;[IO.File]::SetLastWriteTimeUtc($candidateContentPath,$candidateContentMtime)}

    $hookSibling=Join-Path $provider 'hook-sibling'
    try{&$runFinalHookCase {param($phase)New-Item -ItemType Directory -Path $script:hookSibling|Out-Null} 'hook 后新增 sibling'}finally{if(Test-Path -LiteralPath $hookSibling){Remove-Item -LiteralPath $hookSibling -Recurse -Force}}

    $missingRootPath=@($validated.evaluatedRoots|Where-Object{-not$_.exists}|Select-Object -First 1)[0].path
    try{&$runFinalHookCase {param($phase)New-Item -ItemType Directory -Force -Path $script:missingRootPath|Out-Null} 'hook 后声明 root 从缺失变存在'}finally{if(Test-Path -LiteralPath $missingRootPath){Remove-Item -LiteralPath $missingRootPath -Recurse -Force}}

    $candidatePath=$sourceDocument.candidates[0].path;$candidateHolding=Join-Path $fixtureRoot 'hook-candidate-holding';$candidateJunctionTarget=Join-Path $fixtureRoot 'hook-candidate-target';New-Item -ItemType Directory -Path $candidateJunctionTarget|Out-Null
    try{
        & $runFinalHookCase {param($phase)Move-Item -LiteralPath $script:candidatePath -Destination $script:candidateHolding;New-Item -ItemType Junction -Path $script:candidatePath -Target $script:candidateJunctionTarget|Out-Null} 'hook 后 candidate swap 为 junction'
    }finally{if(Test-Path -LiteralPath $candidatePath){$item=Get-Item -LiteralPath $candidatePath -Force;if(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){Remove-Item -LiteralPath $candidatePath -Force}};if(Test-Path -LiteralPath $candidateHolding){Move-Item -LiteralPath $candidateHolding -Destination $candidatePath}}

    $originalSourceJson=[IO.File]::ReadAllText($published.jsonPath)
    try{&$runFinalHookCase {param($phase)[IO.File]::WriteAllText($script:published.jsonPath,"$script:originalSourceJson ",[Text.UTF8Encoding]::new($false))} 'hook 后源 JSON 漂移'}finally{[IO.File]::WriteAllText($published.jsonPath,$originalSourceJson,[Text.UTF8Encoding]::new($false))}

    $originalSourceMarkdown=[IO.File]::ReadAllText($published.markdownPath);$tamperedSourceMarkdown=[regex]::Replace($originalSourceMarkdown,'(?m)^sourceJsonSha256:\s*[0-9a-f]{64}$','sourceJsonSha256: '+('0'*64))
    try{&$runFinalHookCase {param($phase)[IO.File]::WriteAllText($script:published.markdownPath,$script:tamperedSourceMarkdown,[Text.UTF8Encoding]::new($false))} 'hook 后源 Markdown 漂移'}finally{[IO.File]::WriteAllText($published.markdownPath,$originalSourceMarkdown,[Text.UTF8Encoding]::new($false))}

    $outputHolding=Join-Path $fixtureRoot 'manifest-output-holding';$outputJunctionTarget=Join-Path $fixtureRoot 'manifest-output-target';New-Item -ItemType Directory -Path $outputJunctionTarget|Out-Null
    $message=$null
    try{Invoke-BackupRetentionApplyFinalGate -TrustedPolicyContext $context -DryRunJson $published.jsonPath -DryRunMarkdown $published.markdownPath -InitialSourceSha256 $initialSourceSha -OutputDir $finalOutput -UseAllDryRunCandidates -AfterCandidateCheckHook {param($phase)Move-Item -LiteralPath $script:finalOutput -Destination $script:outputHolding;New-Item -ItemType Junction -Path $script:finalOutput -Target $script:outputJunctionTarget|Out-Null}|Out-Null}catch{$message=$_.Exception.Message}
    finally{if(Test-Path -LiteralPath $finalOutput){$item=Get-Item -LiteralPath $finalOutput -Force;if(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){Remove-Item -LiteralPath $finalOutput -Force}};if(Test-Path -LiteralPath $outputHolding){Move-Item -LiteralPath $outputHolding -Destination $finalOutput}}
    Assert-True(-not[string]::IsNullOrWhiteSpace($message))'hook 后 OutputDir junction 必须失败关闭'
    Assert-True(([IO.File]::ReadAllText($oldManifestJson))-ceq'old-json'-and([IO.File]::ReadAllText($oldManifestMarkdown))-ceq'old-markdown')'OutputDir junction 后旧 manifest pair 必须保持'

    $outputAncestor=Join-Path $fixtureRoot 'manifest-parent';$ancestorOutput=Join-Path $outputAncestor 'manifest';New-Item -ItemType Directory -Force -Path $ancestorOutput|Out-Null
    $ancestorOldJson=Join-Path $ancestorOutput 'backup-retention-apply-manifest.json';$ancestorOldMarkdown=Join-Path $ancestorOutput 'BACKUP-RETENTION-APPLY-MANIFEST.md';[IO.File]::WriteAllText($ancestorOldJson,'old-json',[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($ancestorOldMarkdown,'old-markdown',[Text.UTF8Encoding]::new($false))
    $ancestorHolding=Join-Path $fixtureRoot 'manifest-parent-holding';$ancestorTarget=Join-Path $fixtureRoot 'manifest-parent-target';New-Item -ItemType Directory -Path $ancestorTarget|Out-Null;$message=$null
    try{Invoke-BackupRetentionApplyFinalGate -TrustedPolicyContext $context -DryRunJson $published.jsonPath -DryRunMarkdown $published.markdownPath -InitialSourceSha256 $initialSourceSha -OutputDir $ancestorOutput -UseAllDryRunCandidates -AfterCandidateCheckHook {param($phase)Move-Item -LiteralPath $script:outputAncestor -Destination $script:ancestorHolding;New-Item -ItemType Junction -Path $script:outputAncestor -Target $script:ancestorTarget|Out-Null}|Out-Null}catch{$message=$_.Exception.Message}
    finally{if(Test-Path -LiteralPath $outputAncestor){$item=Get-Item -LiteralPath $outputAncestor -Force;if(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){Remove-Item -LiteralPath $outputAncestor -Force}};if(Test-Path -LiteralPath $ancestorHolding){Move-Item -LiteralPath $ancestorHolding -Destination $outputAncestor}}
    Assert-True(-not[string]::IsNullOrWhiteSpace($message))'hook 后 OutputDir ancestor junction 必须失败关闭'
    Assert-True(([IO.File]::ReadAllText($ancestorOldJson))-ceq'old-json'-and([IO.File]::ReadAllText($ancestorOldMarkdown))-ceq'old-markdown')'OutputDir ancestor junction 后旧 manifest pair 必须保持'

    foreach($case in @(
        @{n='字符串 boolean';m={param($d)$d.coverageComplete='false'}},
        @{n='非整数 schema';m={param($d)$d.schemaVersion=2.0}},
        @{n='旧 schema';m={param($d)$d.schemaVersion=1}},
        @{n='未来 schema';m={param($d)$d.schemaVersion=3}},
        @{n='错误 artifactType';m={param($d)$d.artifactType='forged'}},
        @{n='集合非数组';m={param($d)$d.candidates=$d.candidates[0]}},
        @{n='test policy 伪造 mode';m={param($d)$d.artifactMode='production'}},
        @{n='CodexRoot';m={param($d)$d.CodexRoot=$d.DDriveRoot}},
        @{n='DDriveRoot';m={param($d)$d.DDriveRoot=(Join-Path $d.DDriveRoot 'other')}},
        @{n='retainCount';m={param($d)$d.retainCount=4}},
        @{n='policyId';m={param($d)$d.policyId='forged'}},
        @{n='policyVersion';m={param($d)$d.policyVersion=1}},
        @{n='declared roots';m={param($d)$d.declaredScanRoots=@($d.declaredScanRoots|Select-Object -Skip 1)}},
        @{n='candidate retained 投影调换';m={param($d)$tmp=$d.candidates;$d.candidates=$d.retainedItems;$d.retainedItems=$tmp}},
        @{n='candidate disposition';m={param($d)$d.candidates[0].coverageDisposition='retained'}},
        @{n='groupKey';m={param($d)$d.candidates[0].groupKey='forged'}},
        @{n='backupType';m={param($d)$d.candidates[0].backupType='forged'}},
        @{n='timestamp';m={param($d)$d.candidates[0].timestampUtc='2000-01-01T00:00:00Z'}},
        @{n='retainRank';m={param($d)$d.candidates[0].retainRank=99}},
        @{n='blocksCoverage';m={param($d)$d.candidates[0].blocksCoverage=$true}},
        @{n='顶层 extra property';m={param($d)$d|Add-Member -NotePropertyName smuggled -NotePropertyValue $true}},
        @{n='policy extra property';m={param($d)$d.policy|Add-Member -NotePropertyName smuggled -NotePropertyValue $true}},
        @{n='policy summary 伪造';m={param($d)$d.policy.summary='forged human text'}},
        @{n='缺失 nullable reparseTarget';m={param($d)$d.candidates[0].PSObject.Properties.Remove('reparseTarget')}},
        @{n='coverageNotes 伪造';m={param($d)$d.coverageNotes[0]='forged coverage note'}},
        @{n='evaluatedRoot enumerationStarted 伪造';m={param($d)$d.evaluatedRoots[0].enumerationStarted='2000-01-01T00:00:00.0000000Z'}},
        @{n='summary candidateCount 篡改';m={param($d)$d.summary.candidateCount=999}},
        @{n='summary candidateBytes 篡改';m={param($d)$d.summary.candidateBytes=999999999}}
    )){
        $copy=Copy-Document $document; & $case.m $copy; Assert-Rejected { Test-BackupRetentionDryRunDocument -Document $copy -TrustedPolicyContext $context } $case.n
    }

    $duplicate=Copy-Document $document; $duplicate.candidates=@($duplicate.candidates)+@($duplicate.candidates[0]); Assert-Rejected {Test-BackupRetentionDryRunDocument $duplicate $context} '重复 candidate'
    $duplicate=Copy-Document $document; $duplicate.coverageItems=@($duplicate.coverageItems)+@($duplicate.coverageItems[0]); Assert-Rejected {Test-BackupRetentionDryRunDocument $duplicate $context} '重复 canonical path'
    $candidatePath=$document.candidates[0].path
    Assert-Rejected {Resolve-BackupRetentionCandidateSelection -Candidates @($document.candidates) -AllowPath @($candidatePath,$candidatePath)} '重复 AllowPath'
    $ancestorCandidate=Copy-Document $document.candidates[0];$ancestorCandidate.path=$codexRoot
    Assert-Rejected {Assert-BackupRetentionCandidateLiveState -Candidate $ancestorCandidate -TrustedPolicyContext $context -LiveEvaluation $evaluation} '保护/人工审查祖先 candidate'

    $sibling=Join-Path $provider 'unknown-sibling'; New-Item -ItemType Directory -Path $sibling|Out-Null
    Assert-Rejected {Test-BackupRetentionDryRunDocument $document $context} '新增 sibling TOCTOU'
    Remove-Item -LiteralPath $sibling -Recurse -Force
    $reparseTarget=Join-Path $fixtureRoot 'reparse-target';New-Item -ItemType Directory -Path $reparseTarget|Out-Null
    $reparseChild=Join-Path $document.candidates[0].path 'reparse-child';New-Item -ItemType Junction -Path $reparseChild -Target $reparseTarget|Out-Null
    Assert-Rejected {Test-BackupRetentionDryRunDocument $document $context} 'candidate reparse 漂移'
    Remove-Item -LiteralPath $reparseChild -Force

    $candidatePath=$document.candidates[0].path;$candidateHolding=Join-Path $fixtureRoot 'candidate-before-validation'
    Move-Item -LiteralPath $candidatePath -Destination $candidateHolding
    New-Item -ItemType Junction -Path $candidatePath -Target $reparseTarget|Out-Null
    try {
        Assert-True (((Get-Item -LiteralPath $candidatePath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) 'fixture 必须把 candidate 目录真实替换为 junction'
        Assert-Rejected {Test-BackupRetentionDryRunDocument $document $context} '纯验证前 candidate 路径 swap 为 junction'
    } finally {
        if(Test-Path -LiteralPath $candidatePath){Remove-Item -LiteralPath $candidatePath -Force}
        Move-Item -LiteralPath $candidateHolding -Destination $candidatePath
    }

    $fresh=Test-BackupRetentionDryRunDocument $document $context
    $candidateHolding=Join-Path $fixtureRoot 'candidate-after-validation'
    Move-Item -LiteralPath $candidatePath -Destination $candidateHolding
    New-Item -ItemType Junction -Path $candidatePath -Target $reparseTarget|Out-Null
    try {
        Assert-True (((Get-Item -LiteralPath $candidatePath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) 'fixture 必须在纯验证后真实 swap candidate 为 junction'
        Assert-Rejected {Assert-BackupRetentionCandidateLiveState -Candidate $fresh.candidates[0] -TrustedPolicyContext $context -LiveEvaluation $fresh} '纯验证后 candidate swap 为 junction'
    } finally {
        if(Test-Path -LiteralPath $candidatePath){Remove-Item -LiteralPath $candidatePath -Force}
        Move-Item -LiteralPath $candidateHolding -Destination $candidatePath
    }

    Set-Content -LiteralPath (Join-Path $document.candidates[0].path 'stats-drift.txt') -Value drift
    Assert-Rejected {Assert-BackupRetentionCandidateLiveState -Candidate $document.candidates[0] -TrustedPolicyContext $context -LiveEvaluation $fresh} 'candidate 二次 stats 漂移'
} finally {
    if(Test-Path -LiteralPath $fixtureRoot){Assert-CanRemoveFixture $fixtureRoot;Remove-Item -LiteralPath $fixtureRoot -Recurse -Force}
}
[pscustomobject]@{ok=$true}
