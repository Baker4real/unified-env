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
    $text=@($Candidate.groupKey,$Candidate.path,$Candidate.timestampUtc,$Candidate.timestampSource,$Candidate.stats.bytes,$Candidate.stats.files,$Candidate.stats.dirs,$Candidate.stats.newestUtc,$Candidate.stats.oldestUtc)-join"`n"
    return (Get-BackupRetentionSha256 $text).Substring(0,16)
}
function Escape-BackupRetentionApplyMarkdown { param([object]$Value) if($null-eq$Value){return''};return("$Value"-replace'\|','\|'-replace"`r",' '-replace"`n",' ').Trim() }

# 1. 原始输入文件读取与 SHA-256；此阶段及全部验证阶段均不创建 OutputDir。
$DryRunJson=Assert-BackupRetentionApplyEvidencePath -Path $DryRunJson -Name 'DryRunJson'
if(-not(Test-Path -LiteralPath $DryRunJson -PathType Leaf)){throw "DryRunJson 不存在：$DryRunJson"}
$rawBytes=[IO.File]::ReadAllBytes($DryRunJson)
$sourceSha256=Get-BackupRetentionRawFileSha256 $rawBytes

# 2. 严格 JSON 解析，保留日期字符串的 JSON 原生类型。
try{$jsonText=[Text.UTF8Encoding]::new($false,$true).GetString($rawBytes);$dryRun=$jsonText|ConvertFrom-Json -DateKind String -ErrorAction Stop}catch{throw "DryRunJson 不是严格 UTF-8 JSON：$($_.Exception.Message)"}

# 3. 输入必须是共享发布器生成且仍然匹配的 JSON/Markdown 报告对。
$dryRunMarkdown=Join-Path (Split-Path -Parent $DryRunJson) 'BACKUP-RETENTION-DRY-RUN.md'
$pairValidation=Test-JsonMarkdownArtifactPair -JsonPath $DryRunJson -MarkdownPath $dryRunMarkdown
if(-not$pairValidation.ok){throw "DryRunJson 报告对校验失败：$($pairValidation.error)"}
if($pairValidation.sourceJsonSha256-cne$sourceSha256){throw 'DryRunJson 报告对校验期间 JSON 发生漂移。'}
if($dryRun.PSObject.Properties.Name-notcontains'generationId'-or$dryRun.generationId-cne$pairValidation.generationId){throw 'DryRunJson 报告对 generationId 不一致。'}

# 4. freshness gate（严格不超过 24 小时且不得来自未来）。
if($MaxDryRunAgeHours-lt1-or$MaxDryRunAgeHours-gt24){throw 'MaxDryRunAgeHours 必须在 1..24。'}
Assert-BackupRetentionProperty $dryRun 'generatedAtUtc'|Out-Null;Assert-BackupRetentionString $dryRun.generatedAtUtc 'generatedAtUtc'
$generated=[datetimeoffset]::MinValue
if(-not[datetimeoffset]::TryParseExact($dryRun.generatedAtUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal,[ref]$generated)){throw 'generatedAtUtc 必须是严格 ISO 8601 round-trip 字符串。'}
$age=((Get-Date).ToUniversalTime()-$generated.UtcDateTime).TotalHours
if($age-lt-0.05){throw 'DryRunJson 生成时间来自未来。'};if($age-gt$MaxDryRunAgeHours){throw "DryRunJson 已超过 $MaxDryRunAgeHours 小时。"}

# 5. 正式入口只构造固定 production context。
$context=New-BackupRetentionPolicyContext -ArtifactMode production -CodexRoot 'D:\Codex\.codex' -DDriveRoot 'D:\Codex' -RetainCount 5

# 6. 无写入纯验证器现场复算所有声明根并做全语义/快照比较。
$live=Test-BackupRetentionDryRunDocument -Document $dryRun -TrustedPolicyContext $context

# 7. selection allowlist gate。
$selected=@(Resolve-BackupRetentionCandidateSelection -Candidates @($live.candidates) -UseAllDryRunCandidates:$UseAllDryRunCandidates -AllowPath $AllowPath)

# 8. 每个已选 candidate 在发布前再做一次路径 metadata 与 stats 校验。
$items=[Collections.Generic.List[object]]::new()
foreach($candidate in $selected){
    $current=Assert-BackupRetentionCandidateLiveState -Candidate $candidate -TrustedPolicyContext $context -LiveEvaluation $live
    $items.Add([pscustomobject][ordered]@{candidateId=Get-BackupRetentionCandidateId $candidate;selected=$true;validationStatus='ready-for-final-authorization';blockers=[object[]]@();path=$candidate.path;bucket=$candidate.bucket;groupKey=$candidate.groupKey;projectRoot=$candidate.projectRoot;backupType=$candidate.backupType;risk=$candidate.risk;reason=$candidate.reason;retainRank=$candidate.retainRank;timestampUtc=$candidate.timestampUtc;timestampSource=$candidate.timestampSource;plannedOperation='recursive-delete-directory-after-final-confirmation';originalStats=$candidate.stats;currentStats=$current;reparse=[pscustomobject]@{isReparsePoint=$false;hasReparsePoint=$false;firstReparsePoint=$null;target=$null}})
}

# 9. schema 2 manifest model。
$readyBytes=[int64](($items|ForEach-Object{[int64]$_.currentStats.bytes}|Measure-Object -Sum).Sum)
$manifestId='backup-retention-apply-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+(Get-BackupRetentionSha256 ($sourceSha256+(@($items.path)-join"`n"))).Substring(0,8)
$manifest=[pscustomobject][ordered]@{
    artifactType='env-governance.backup-retention-apply-manifest';schemaVersion=2;manifestId=$manifestId
    generatedAtLocal=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz');generatedAtUtc=(Get-Date).ToUniversalTime().ToString('o')
    applyManifestOnly=$true;readOnly=$true;deleteAllowed=$false;executionReady=$false
    selectionMode=if($UseAllDryRunCandidates){'all-dry-run-candidates'}else{'explicit-allow-paths'}
    sourceDryRun=[pscustomobject][ordered]@{jsonPath=$DryRunJson;sourceJsonSha256=$sourceSha256;generatedAtUtc=$dryRun.generatedAtUtc;artifactType=$dryRun.artifactType;schemaVersion=$dryRun.schemaVersion;candidateCount=@($live.candidates).Count}
    trustedPolicyContext=$context
    rootSnapshots=[object[]]@($live.evaluatedRoots|ForEach-Object{[pscustomobject]@{rootId=$_.rootId;path=$_.path;exists=$_.exists;enumerationCompleted=$_.enumerationCompleted;directChildCount=$_.directChildCount;snapshotSha256=$_.snapshotSha256}})
    policy=[pscustomobject][ordered]@{summary='只读 apply manifest；不删除任何内容。';requiresFinalUserAuthorization=$true;stateFingerprintRequired=$true;reparsePointCheckRequired=$true;futureApplyConfirmationPhrase="我确认删除 manifest $manifestId 中的 $($items.Count) 个已验证路径，预计释放 $([math]::Round($readyBytes/1MB,2)) MB"}
    summary=[pscustomobject][ordered]@{sourceCandidateCount=@($live.candidates).Count;selectedCount=$items.Count;readyForFinalAuthorizationCount=$items.Count;blockedCount=0;readyBytes=$readyBytes;readyMb=[math]::Round($readyBytes/1MB,2);dryRunAgeHours=[math]::Round($age,2)}
    items=[object[]]@($items.ToArray()|Sort-Object groupKey,retainRank,path);blockedItems=[object[]]@()
}

# 10. 仅全部前置门成功后校验 OutputDir 并通过共享发布器写入。
if([string]::IsNullOrWhiteSpace($OutputDir)){$OutputDir="D:\Codex\projects\统一环境\reports\backup-retention-apply-manifest-$(Get-Date -Format 'yyyyMMdd-HHmmss')"}
$OutputDir=Assert-BackupRetentionApplyEvidencePath -Path $OutputDir -Name 'OutputDir'
$published=Publish-JsonMarkdownArtifactPair -Document $manifest -OutputDir $OutputDir -JsonFileName 'backup-retention-apply-manifest.json' -MarkdownFileName 'BACKUP-RETENTION-APPLY-MANIFEST.md' -RenderMarkdown {
    param($Document,$JsonSha256)
    $lines=[Collections.Generic.List[string]]::new();$lines.Add('# 备份清理 apply manifest');$lines.Add('');$lines.Add("manifest id：$($Document.manifestId)");$lines.Add('');$lines.Add("源 dry-run SHA-256：$($Document.sourceDryRun.sourceJsonSha256)");$lines.Add("manifest JSON SHA-256：$JsonSha256");$lines.Add("deleteAllowed=false；executionReady=false；通过二次校验：$($Document.summary.readyForFinalAuthorizationCount) 个。");$lines.Add('');$lines.Add('真实删除仍需用户最终授权；本脚本不删除、不移动任何文件。');$lines.Add('');$lines.Add('| id | 组 | 排名 | 路径 |');$lines.Add('| --- | --- | ---: | --- |');foreach($item in @($Document.items)){$lines.Add("| $($item.candidateId) | $(Escape-BackupRetentionApplyMarkdown $item.groupKey) | $($item.retainRank) | $(Escape-BackupRetentionApplyMarkdown $item.path) |")};return $lines.ToArray()-join"`n"
}
[pscustomobject]@{ok=$true;applyManifestOnly=$true;readOnly=$true;deleteAllowed=$false;executionReady=$false;manifestId=$manifestId;outputDir=$OutputDir;manifestPath=$published.jsonPath;reportPath=$published.markdownPath;selectedCount=$items.Count;readyForFinalAuthorizationCount=$items.Count;blockedCount=0;readyMb=$manifest.summary.readyMb}
