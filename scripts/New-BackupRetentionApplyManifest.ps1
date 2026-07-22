param(
    [Parameter(Mandatory)][string]$DryRunJson,
    [string]$OutputDir='',
    [switch]$UseAllDryRunCandidates,
    [string[]]$AllowPath=@(),
    [int]$MaxDryRunAgeHours=24
)
$ErrorActionPreference='Stop'
$libraryRoot=Join-Path $PSScriptRoot 'lib'
. (Join-Path $libraryRoot 'BackupRetentionPolicy.ps1')
. (Join-Path $libraryRoot 'BackupRetentionValidation.ps1')
. (Join-Path $libraryRoot 'ReportArtifactPublisher.ps1')

function Test-BackupRetentionApplySubPath { param([string]$Path,[string]$BasePath)
    $full=Get-BackupRetentionCanonicalPath $Path;$base=Get-BackupRetentionCanonicalPath $BasePath
    return $full-ieq$base-or$full.StartsWith("$($base.TrimEnd('\'))\",[StringComparison]::OrdinalIgnoreCase)
}
function Assert-BackupRetentionApplyEvidencePath { param([string]$Path,[string]$Name)
    $full=Assert-BackupRetentionDPath -Path $Path -Name $Name
    $allowed=@('D:\Codex\projects\统一环境\reports','D:\Codex\.codex\run-evidence\env-governance')
    if(@($allowed|Where-Object{Test-BackupRetentionApplySubPath $full $_}).Count-eq0){throw "$Name 不在允许的 env-governance 证据根中：$full"}
    return $full
}
function Get-BackupRetentionRawFileSha256 { param([byte[]]$Bytes) return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant() }
function Get-BackupRetentionCandidateId { param($Candidate)
    $text=@($Candidate.groupKey,$Candidate.path,$Candidate.timestampUtc,$Candidate.timestampSource,$Candidate.stats.bytes,$Candidate.stats.files,$Candidate.stats.dirs,$Candidate.stats.newestUtc,$Candidate.stats.oldestUtc,$Candidate.stats.treeSha256)-join"`n"
    return (Get-BackupRetentionSha256 $text).Substring(0,16)
}
function Escape-BackupRetentionApplyMarkdown { param([object]$Value) if($null-eq$Value){return''};return("$Value"-replace'\|','\|'-replace"`r",' '-replace"`n",' ').Trim() }

# 1. 原始输入文件读取与 SHA-256；此阶段及全部验证阶段均不创建 OutputDir。
$DryRunJson=Assert-BackupRetentionApplyEvidencePath -Path $DryRunJson -Name 'DryRunJson'
if(-not(Test-Path -LiteralPath $DryRunJson -PathType Leaf)){throw "DryRunJson 不存在：$DryRunJson"}
$rawBytes=[IO.File]::ReadAllBytes($DryRunJson)
$sourceSha256=Get-BackupRetentionRawFileSha256 $rawBytes

# 2. 严格 UTF-8 与 JSON 词法解析；在 PowerShell 对象转换前拒绝尾随逗号、注释和重复属性。
try{$jsonText=[Text.UTF8Encoding]::new($false,$true).GetString($rawBytes)}catch{throw "DryRunJson 不是严格 UTF-8：$($_.Exception.Message)"}
Assert-BackupRetentionStrictJsonText -JsonText $jsonText
try{$dryRun=$jsonText|ConvertFrom-Json -DateKind String -ErrorAction Stop}catch{throw "DryRunJson 无法转换为对象：$($_.Exception.Message)"}

# 3. 输入必须是共享发布器生成且仍然匹配的 JSON/Markdown 报告对。
$dryRunMarkdown=Assert-BackupRetentionApplyEvidencePath -Path (Join-Path (Split-Path -Parent $DryRunJson) 'BACKUP-RETENTION-DRY-RUN.md') -Name 'DryRunMarkdown'
$pairValidation=Test-JsonMarkdownArtifactPair -JsonPath $DryRunJson -MarkdownPath $dryRunMarkdown
if(-not$pairValidation.ok){throw "DryRunJson 报告对校验失败：$($pairValidation.error)"}
if($pairValidation.sourceJsonSha256-cne$sourceSha256){throw 'DryRunJson 报告对校验期间 JSON 发生漂移。'}
if($dryRun.PSObject.Properties.Name-notcontains'generationId'-or$dryRun.generationId-cne$pairValidation.generationId){throw 'DryRunJson 报告对 generationId 不一致。'}

# 4. 固定 freshness policy 上限；此处只做快速失败，最终授权依据由 final gate 重新读取时钟。
if($MaxDryRunAgeHours-lt1-or$MaxDryRunAgeHours-gt24){throw 'MaxDryRunAgeHours 必须在 1..24。'}
# 早期 preflight 仅用于快速失败；manifest 年龄与授权依据仍只消费 final gate 的最终时钟读数。
Test-BackupRetentionDryRunFreshness -Document $dryRun -MaxDryRunAgeHours $MaxDryRunAgeHours|Out-Null

# 5. 正式入口只构造固定 production context。
$context=New-BackupRetentionPolicyContext -ArtifactMode production -CodexRoot 'D:\Codex\.codex' -DDriveRoot 'D:\Codex' -RetainCount 5

# 6. 先确定但不创建 OutputDir；final gate 会在最终复算前后检查完整父链。
if([string]::IsNullOrWhiteSpace($OutputDir)){$OutputDir="D:\Codex\projects\统一环境\reports\backup-retention-apply-manifest-$(Get-Date -Format 'yyyyMMdd-HHmmss')"}
$OutputDir=Assert-BackupRetentionApplyEvidencePath -Path $OutputDir -Name 'OutputDir'

# 7. 完整初检、candidate 当前校验与最终全门复算；正式入口不暴露 phase hook。
$finalGate=Invoke-BackupRetentionApplyFinalGate -TrustedPolicyContext $context -DryRunJson $DryRunJson -DryRunMarkdown $dryRunMarkdown -InitialSourceSha256 $sourceSha256 -OutputDir $OutputDir -MaxDryRunAgeHours $MaxDryRunAgeHours -UseAllDryRunCandidates:$UseAllDryRunCandidates -AllowPath $AllowPath
$dryRun=$finalGate.sourceDocument;$sourceSha256=$finalGate.sourceJsonSha256;$live=$finalGate.liveEvaluation;$selected=@($finalGate.selectedCandidates);$OutputDir=$finalGate.outputDir
Assert-BackupRetentionApplyCandidateItemTypes -Candidates $selected

# 8. manifest item 只消费最终 gate 返回的 directory candidate 与内容树指纹。
$items=[Collections.Generic.List[object]]::new()
foreach($validatedCandidate in @($finalGate.validatedCandidates)){
    $candidate=$validatedCandidate.candidate;$current=$validatedCandidate.currentStats
    $items.Add([pscustomobject][ordered]@{candidateId=Get-BackupRetentionCandidateId $candidate;selected=$true;validationStatus='ready-for-final-authorization';blockers=[object[]]@();path=$candidate.path;bucket=$candidate.bucket;groupKey=$candidate.groupKey;projectRoot=$candidate.projectRoot;backupType=$candidate.backupType;risk=$candidate.risk;reason=$candidate.reason;retainRank=$candidate.retainRank;timestampUtc=$candidate.timestampUtc;timestampSource=$candidate.timestampSource;plannedOperation='recursive-delete-directory-after-final-confirmation';stateFingerprint=[pscustomobject][ordered]@{algorithm='sha256-tree-v1';treeSha256=$current.treeSha256;sourceJsonSha256=$sourceSha256};originalStats=$candidate.stats;currentStats=$current;reparse=[pscustomobject]@{isReparsePoint=$false;hasReparsePoint=$false;firstReparsePoint=$null;target=$null}})
}

# 9. schema 2 manifest model。
$readyBytes=[int64](($items|ForEach-Object{[int64]$_.currentStats.bytes}|Measure-Object -Sum).Sum)
$manifestId='backup-retention-apply-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+(Get-BackupRetentionSha256 ($sourceSha256+(@($items.path)-join"`n"))).Substring(0,8)
$manifest=[pscustomobject][ordered]@{
    artifactType='env-governance.backup-retention-apply-manifest';schemaVersion=2;manifestId=$manifestId
    generatedAtLocal=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz');generatedAtUtc=(Get-Date).ToUniversalTime().ToString('o')
    applyManifestOnly=$true;readOnly=$true;deleteAllowed=$false;executionReady=$false
    selectionMode=if($UseAllDryRunCandidates){'all-dry-run-candidates'}else{'explicit-allow-paths'}
    sourceDryRun=[pscustomobject][ordered]@{jsonPath=$DryRunJson;sourceJsonSha256=$sourceSha256;generatedAtUtc=$dryRun.generatedAtUtc;validatedAtUtc=$finalGate.validatedAtUtc;artifactType=$dryRun.artifactType;schemaVersion=$dryRun.schemaVersion;candidateCount=@($live.candidates).Count}
    trustedPolicyContext=$context
    rootSnapshots=[object[]]@($live.evaluatedRoots|ForEach-Object{[pscustomobject]@{rootId=$_.rootId;path=$_.path;exists=$_.exists;enumerationCompleted=$_.enumerationCompleted;directChildCount=$_.directChildCount;snapshotSha256=$_.snapshotSha256}})
    policy=[pscustomobject][ordered]@{summary='只读 apply manifest；不删除任何内容。';requiresFinalUserAuthorization=$true;stateFingerprintRequired=$true;reparsePointCheckRequired=$true;finalExecutionMustRevalidate=$true;futureApplyConfirmationPhrase="我确认删除 manifest $manifestId 中的 $($items.Count) 个已验证路径，预计释放 $([math]::Round($readyBytes/1MB,2)) MB"}
    summary=[pscustomobject][ordered]@{sourceCandidateCount=@($live.candidates).Count;selectedCount=$items.Count;readyForFinalAuthorizationCount=$items.Count;blockedCount=0;readyBytes=$readyBytes;readyMb=[math]::Round($readyBytes/1MB,2);dryRunAgeHours=[math]::Round($finalGate.finalAgeHours,2)}
    items=[object[]]@($items.ToArray()|Sort-Object groupKey,retainRank,path);blockedItems=[object[]]@()
}

# 10. 仅全部前置门成功后再次校验 OutputDir 并通过共享发布器写入。
$OutputDir=Assert-BackupRetentionApplyEvidencePath -Path $OutputDir -Name 'OutputDir'
$published=Publish-JsonMarkdownArtifactPair -Document $manifest -OutputDir $OutputDir -JsonFileName 'backup-retention-apply-manifest.json' -MarkdownFileName 'BACKUP-RETENTION-APPLY-MANIFEST.md' -RenderMarkdown {
    param($Document,$JsonSha256)
    $lines=[Collections.Generic.List[string]]::new();$lines.Add('# 备份清理 apply manifest');$lines.Add('');$lines.Add("manifest id：$($Document.manifestId)");$lines.Add('');$lines.Add("源 dry-run SHA-256：$($Document.sourceDryRun.sourceJsonSha256)");$lines.Add("manifest JSON SHA-256：$JsonSha256");$lines.Add("deleteAllowed=false；executionReady=false；通过二次校验：$($Document.summary.readyForFinalAuthorizationCount) 个。");$lines.Add('');$lines.Add('真实删除仍需用户最终授权；真正执行删除前必须再次完整复算源报告、根快照、reparse 链和 candidate treeSha256。本脚本不删除、不移动任何文件。');$lines.Add('');$lines.Add('| id | 组 | 排名 | tree SHA-256 | 路径 |');$lines.Add('| --- | --- | ---: | --- | --- |');foreach($item in @($Document.items)){$lines.Add("| $($item.candidateId) | $(Escape-BackupRetentionApplyMarkdown $item.groupKey) | $($item.retainRank) | $($item.stateFingerprint.treeSha256) | $(Escape-BackupRetentionApplyMarkdown $item.path) |")};return $lines.ToArray()-join"`n"
}
[pscustomobject]@{ok=$true;applyManifestOnly=$true;readOnly=$true;deleteAllowed=$false;executionReady=$false;manifestId=$manifestId;outputDir=$OutputDir;manifestPath=$published.jsonPath;reportPath=$published.markdownPath;selectedCount=$items.Count;readyForFinalAuthorizationCount=$items.Count;blockedCount=0;readyMb=$manifest.summary.readyMb}
