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
    $doc=[pscustomobject][ordered]@{
        artifactType='env-governance.backup-retention-dry-run'; schemaVersion=2; artifactMode=$Context.artifactMode
        generatedAtLocal=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'); generatedAtUtc=(Get-Date).ToUniversalTime().ToString('o')
        dryRun=$true; readOnly=$true; deleteAllowed=$false; applySupported=$false; executionAllowed=$false
        CodexRoot=$Context.CodexRoot; DDriveRoot=$Context.DDriveRoot; retainCount=$Context.retainCount; policyId=$Context.policyId; policyVersion=$Context.policyVersion
        policy=[pscustomobject]@{policyId=$Context.policyId;policyVersion=$Context.policyVersion;applyMustUseAllowlist=$true;applyMustCheckReparsePoints=$true}
        declaredScanRoots=[object[]]$Evaluation.declaredScanRoots; evaluatedRoots=[object[]]$Evaluation.evaluatedRoots; coverageItems=[object[]]$Evaluation.coverageItems
        candidates=[object[]]$Evaluation.candidates; retainedItems=[object[]]$Evaluation.retainedItems; protected=[object[]]$Evaluation.protected; manualReview=[object[]]$Evaluation.manualReview
        unclassifiedCoverageGaps=[object[]]$Evaluation.unclassifiedCoverageGaps; coverageAccounted=[bool]$Evaluation.coverageAccounted; coverageComplete=[bool]$Evaluation.coverageComplete
        coverageNotes=[object[]]$Evaluation.coverageNotes; errors=[object[]]$Evaluation.errors
        summary=[pscustomobject]@{candidateCount=@($Evaluation.candidates).Count;candidateBytes=$candidateBytes;candidateMb=[math]::Round($candidateBytes/1MB,2);manualReviewCount=@($Evaluation.manualReview).Count;manualReviewMb=0.0}
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
    $codexRoot=Join-Path $fixtureRoot '.codex'; $provider=Join-Path $codexRoot 'backups_state\provider-sync'
    New-Item -ItemType Directory -Force -Path $provider|Out-Null
    foreach($name in @('20260701T000006Z','20260701T000005Z','20260701T000004Z','20260701T000003Z','20260701T000002Z','20260701T000001Z')){New-Item -ItemType Directory -Path (Join-Path $provider $name)|Out-Null}
    $context=New-BackupRetentionPolicyContext -ArtifactMode test -CodexRoot $codexRoot -DDriveRoot $fixtureRoot
    $evaluation=Invoke-BackupRetentionEvaluation -PolicyContext $context
    Assert-True $evaluation.coverageComplete '可信 fixture 必须 coverageComplete=true'
    $document=New-TestDocument $context $evaluation
    $validated=Test-BackupRetentionDryRunDocument -Document $document -TrustedPolicyContext $context
    Assert-True (@($validated.candidates).Count -eq 1) '纯验证器应返回现场复算结果'

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
        @{n='blocksCoverage';m={param($d)$d.candidates[0].blocksCoverage=$true}}
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
