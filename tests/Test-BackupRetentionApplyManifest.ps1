param([string]$ProjectRoot='D:\Codex\projects\统一环境',[switch]$KeepOutputs)
$ErrorActionPreference='Stop'
function Assert-True{param([bool]$Condition,[string]$Message)if(-not$Condition){throw $Message}}
function Assert-RejectedWithoutOutput{param([scriptblock]$Action,[string]$OutputDir,[string]$Label)
    $blocked=$false;try{&$Action|Out-Null}catch{$blocked=$true};Assert-True $blocked "$Label 必须失败关闭";Assert-True(-not(Test-Path -LiteralPath $OutputDir))"$Label 不得创建 OutputDir"
}
function Assert-RejectedWithMessageWithoutOutput{param([scriptblock]$Action,[string]$OutputDir,[string]$Pattern,[string]$Label)
    $message=$null;try{&$Action|Out-Null}catch{$message=$_.Exception.Message}
    Assert-True ($message -like $Pattern) "$Label 必须由目标安全门拒绝，期望 $Pattern，实际：$message"
    Assert-True(-not(Test-Path -LiteralPath $OutputDir))"$Label 不得创建 OutputDir"
}
function Assert-PairRejectedWithoutOutput{param([scriptblock]$Action,[string]$OutputDir,[string]$Label)
    $message=$null;try{&$Action|Out-Null}catch{$message=$_.Exception.Message}
    Assert-True (-not [string]::IsNullOrWhiteSpace($message)) "$Label 必须失败关闭"
    Assert-True ($message -like '*报告对*') "$Label 必须由 JSON/Markdown 报告对门拒绝，实际：$message"
    Assert-True(-not(Test-Path -LiteralPath $OutputDir))"$Label 不得创建 OutputDir"
}
function Assert-CanRemoveTestRoot{param([string]$Path)
    $full=[IO.Path]::GetFullPath($Path);$reports=[IO.Path]::GetFullPath((Join-Path $ProjectRoot 'reports'))
    Assert-True($full.StartsWith("$($reports.TrimEnd('\'))\",[StringComparison]::OrdinalIgnoreCase))'测试根必须位于 reports 子树'
    $current=$full;while($current.StartsWith($reports,[StringComparison]::OrdinalIgnoreCase)){if(Test-Path -LiteralPath $current){Assert-True(((Get-Item -LiteralPath $current -Force).Attributes-band[IO.FileAttributes]::ReparsePoint)-eq0)'测试根父链不得有 reparse point'};if($current-ieq$reports){break};$current=[IO.Directory]::GetParent($current).FullName}
}
function Write-TestJsonPair{param($Document,[string]$Path)
    $jsonText=$Document|ConvertTo-Json -Depth 100
    Write-RawTestJsonPair -JsonText $jsonText -GenerationId $Document.generationId -Path $Path
}
function Write-RawTestJsonPair{param([string]$JsonText,[string]$GenerationId,[string]$Path)
    [IO.File]::WriteAllText($Path,$jsonText,[Text.UTF8Encoding]::new($false))
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($jsonText))).ToLowerInvariant()
    $markdown="---`ngenerationId: $GenerationId`nsourceJsonSha256: $hash`n---`nfixture"
    [IO.File]::WriteAllText((Join-Path (Split-Path -Parent $Path) 'BACKUP-RETENTION-DRY-RUN.md'),$markdown,[Text.UTF8Encoding]::new($false))
}

$dryRunScript=Join-Path $ProjectRoot 'scripts\New-BackupRetentionDryRun.ps1';$applyScript=Join-Path $ProjectRoot 'scripts\New-BackupRetentionApplyManifest.ps1'
$testRoot=Join-Path $ProjectRoot 'reports\backup-retention-apply-manifest-test';$fixture=Join-Path $testRoot 'fixture';$codex=Join-Path $fixture '.codex';$provider=Join-Path $codex 'backups_state\provider-sync';$dryOutput=Join-Path $testRoot 'dry-run'
try{
    Assert-CanRemoveTestRoot $testRoot;if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force}
    New-Item -ItemType Directory -Force -Path $provider|Out-Null
    foreach($name in @('20260701T000006Z','20260701T000005Z','20260701T000004Z','20260701T000003Z','20260701T000002Z','20260701T000001Z')){New-Item -ItemType Directory -Path(Join-Path $provider $name)|Out-Null}
    &$dryRunScript -ArtifactMode test -CodexRoot $codex -DDriveRoot $fixture -OutputDir $dryOutput|Out-Null
    $jsonPath=Join-Path $dryOutput 'backup-retention-dry-run.json';$markdownPath=Join-Path $dryOutput 'BACKUP-RETENTION-DRY-RUN.md';$doc=Get-Content -Raw -LiteralPath $jsonPath|ConvertFrom-Json -DateKind String
    $originalMarkdown=[IO.File]::ReadAllText($markdownPath)

    $source=Get-Content -Raw -LiteralPath $applyScript
    Assert-True(-not($source-match'\bRemove-Item\b'))'apply manifest 入口不得包含删除实现'
    Assert-True(-not($source-match'\bMove-Item\b'))'apply manifest 入口不得包含移动实现'
    Assert-True(-not$source.Contains('AfterCandidateCheckHook'))'正式 apply 参数面不得暴露测试 phase hook'
    Assert-True(-not$source.Contains('NowProvider'))'正式 apply 参数面不得暴露测试时钟注入'
    foreach($needle in @('BackupRetentionValidation.ps1','ReportArtifactPublisher.ps1','env-governance.backup-retention-apply-manifest','schemaVersion=2','sourceJsonSha256','Test-JsonMarkdownArtifactPair','Assert-BackupRetentionStrictJsonText','Invoke-BackupRetentionApplyFinalGate','-MaxDryRunAgeHours $MaxDryRunAgeHours','validatedAtUtc=$finalGate.validatedAtUtc','dryRunAgeHours=[math]::Round($finalGate.finalAgeHours','stateFingerprint','treeSha256','finalExecutionMustRevalidate','Publish-JsonMarkdownArtifactPair')){Assert-True $source.Contains($needle)"apply 入口缺少必需安全链：$needle"}
    $readIndex=$source.IndexOf('[IO.File]::ReadAllBytes');$strictIndex=$source.IndexOf('Assert-BackupRetentionStrictJsonText');$parseIndex=$source.IndexOf('ConvertFrom-Json -DateKind String');$pairIndex=$source.IndexOf('Test-JsonMarkdownArtifactPair');$contextIndex=$source.IndexOf('New-BackupRetentionPolicyContext -ArtifactMode production');$finalGateIndex=$source.IndexOf('Invoke-BackupRetentionApplyFinalGate');$modelIndex=$source.IndexOf('# 9. schema 2 manifest model');$publishIndex=$source.IndexOf('Publish-JsonMarkdownArtifactPair')
    Assert-True($readIndex-lt$strictIndex-and$strictIndex-lt$parseIndex-and$parseIndex-lt$pairIndex-and$pairIndex-lt$contextIndex-and$contextIndex-lt$finalGateIndex-and$finalGateIndex-lt$modelIndex-and$modelIndex-lt$publishIndex)'apply 安全门顺序必须固定'

    $heldMarkdown="$markdownPath.held";Move-Item -LiteralPath $markdownPath -Destination $heldMarkdown
    try{$out=Join-Path $testRoot 'missing-pair-output';Assert-PairRejectedWithoutOutput {&$applyScript -DryRunJson $jsonPath -UseAllDryRunCandidates -OutputDir $out} $out '缺失 dry-run Markdown'}finally{Move-Item -LiteralPath $heldMarkdown -Destination $markdownPath}

    $markdownJunctionTarget=Join-Path $testRoot 'markdown-junction-target';New-Item -ItemType Directory -Path $markdownJunctionTarget|Out-Null
    Move-Item -LiteralPath $markdownPath -Destination $heldMarkdown;New-Item -ItemType Junction -Path $markdownPath -Target $markdownJunctionTarget|Out-Null
    try{$out=Join-Path $testRoot 'markdown-reparse-output';Assert-RejectedWithMessageWithoutOutput {&$applyScript -DryRunJson $jsonPath -UseAllDryRunCandidates -OutputDir $out} $out '*不得穿过 reparse point*' 'dry-run Markdown leaf junction'}finally{if(Test-Path -LiteralPath $markdownPath){Remove-Item -LiteralPath $markdownPath -Force};Move-Item -LiteralPath $heldMarkdown -Destination $markdownPath}

    $tamperedMarkdown=[regex]::Replace($originalMarkdown,'(?m)^sourceJsonSha256:\s*[0-9a-f]{64}$','sourceJsonSha256: '+('0'*64))
    [IO.File]::WriteAllText($markdownPath,$tamperedMarkdown,[Text.UTF8Encoding]::new($false))
    try{$out=Join-Path $testRoot 'tampered-pair-output';Assert-PairRejectedWithoutOutput {&$applyScript -DryRunJson $jsonPath -UseAllDryRunCandidates -OutputDir $out} $out '篡改 dry-run Markdown'}finally{[IO.File]::WriteAllText($markdownPath,$originalMarkdown,[Text.UTF8Encoding]::new($false))}

    $mismatchedMarkdown=[regex]::Replace($originalMarkdown,'(?m)^generationId:\s*[^\r\n]+$',"generationId: $([guid]::NewGuid())")
    [IO.File]::WriteAllText($markdownPath,$mismatchedMarkdown,[Text.UTF8Encoding]::new($false))
    try{$out=Join-Path $testRoot 'mismatched-pair-output';Assert-PairRejectedWithoutOutput {&$applyScript -DryRunJson $jsonPath -UseAllDryRunCandidates -OutputDir $out} $out '错配 dry-run generationId'}finally{[IO.File]::WriteAllText($markdownPath,$originalMarkdown,[Text.UTF8Encoding]::new($false))}

    $oldOutput=Join-Path $testRoot 'preserve-old-manifest';New-Item -ItemType Directory -Path $oldOutput|Out-Null
    $oldJson=Join-Path $oldOutput 'backup-retention-apply-manifest.json';$oldMarkdown=Join-Path $oldOutput 'BACKUP-RETENTION-APPLY-MANIFEST.md'
    [IO.File]::WriteAllText($oldJson,'old-json',[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($oldMarkdown,'old-markdown',[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($markdownPath,$tamperedMarkdown,[Text.UTF8Encoding]::new($false))
    try{
        $message=$null;try{&$applyScript -DryRunJson $jsonPath -UseAllDryRunCandidates -OutputDir $oldOutput|Out-Null}catch{$message=$_.Exception.Message}
        Assert-True($message -like '*报告对*')"报告对失败必须在发布前拒绝，实际：$message"
        Assert-True(([IO.File]::ReadAllText($oldJson))-ceq'old-json')'报告对失败不得覆盖旧 manifest JSON'
        Assert-True(([IO.File]::ReadAllText($oldMarkdown))-ceq'old-markdown')'报告对失败不得覆盖旧 manifest Markdown'
    }finally{[IO.File]::WriteAllText($markdownPath,$originalMarkdown,[Text.UTF8Encoding]::new($false))}

    $out=Join-Path $testRoot 'test-artifact-rejected';Assert-RejectedWithMessageWithoutOutput {&$applyScript -DryRunJson $jsonPath -UseAllDryRunCandidates -OutputDir $out} $out '*artifactMode*' '正式入口 test artifact'

    $originalJson=[IO.File]::ReadAllText($jsonPath)
    $duplicateJson=[regex]::Replace($originalJson,'^\s*\{','{"artifactType":"duplicate-smuggling",',1)
    $p=Join-Path $testRoot 'duplicate-key.json';Write-RawTestJsonPair -JsonText $duplicateJson -GenerationId $doc.generationId -Path $p;$out=Join-Path $testRoot 'duplicate-key-output'
    Assert-RejectedWithMessageWithoutOutput {&$applyScript -DryRunJson $p -UseAllDryRunCandidates -OutputDir $out} $out '*重复 JSON 属性*' '重复 JSON property name'

    $trailingCommaJson=[regex]::Replace($originalJson,'\}\s*$',',}')
    $p=Join-Path $testRoot 'trailing-comma.json';Write-RawTestJsonPair -JsonText $trailingCommaJson -GenerationId $doc.generationId -Path $p;$out=Join-Path $testRoot 'trailing-comma-output'
    Assert-RejectedWithMessageWithoutOutput {&$applyScript -DryRunJson $p -UseAllDryRunCandidates -OutputDir $out} $out '*严格 JSON 词法*' '尾随逗号'

    $commentJson=[regex]::Replace($originalJson,'^\s*\{','{/*smuggled-comment*/',1)
    $p=Join-Path $testRoot 'comment.json';Write-RawTestJsonPair -JsonText $commentJson -GenerationId $doc.generationId -Path $p;$out=Join-Path $testRoot 'comment-output'
    Assert-RejectedWithMessageWithoutOutput {&$applyScript -DryRunJson $p -UseAllDryRunCandidates -OutputDir $out} $out '*严格 JSON 词法*' 'JSON comment'

    $forged=$doc|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String;$forged.artifactMode='production';$p=Join-Path $testRoot 'forged-production.json';Write-TestJsonPair $forged $p;$out=Join-Path $testRoot 'forged-production-output';Assert-RejectedWithMessageWithoutOutput {&$applyScript -DryRunJson $p -UseAllDryRunCandidates -OutputDir $out} $out '*CodexRoot*' '伪造 production roots'

    $future=$doc|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String;$future.generatedAtUtc=(Get-Date).ToUniversalTime().AddHours(1).ToString('o');$p=Join-Path $testRoot 'future.json';Write-TestJsonPair $future $p;$out=Join-Path $testRoot 'future-output';Assert-RejectedWithMessageWithoutOutput {&$applyScript -DryRunJson $p -UseAllDryRunCandidates -OutputDir $out} $out '*来自未来*' '未来时间'
    $slightlyFuture=$doc|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String;$slightlyFuture.generatedAtUtc=(Get-Date).ToUniversalTime().AddSeconds(30).ToString('o');$p=Join-Path $testRoot 'slightly-future.json';Write-TestJsonPair $slightlyFuture $p;$out=Join-Path $testRoot 'slightly-future-output';Assert-RejectedWithMessageWithoutOutput {&$applyScript -DryRunJson $p -UseAllDryRunCandidates -OutputDir $out} $out '*来自未来*' '任意未来时间'
    $old=$doc|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String;$old.generatedAtUtc=(Get-Date).ToUniversalTime().AddHours(-25).ToString('o');$p=Join-Path $testRoot 'old.json';Write-TestJsonPair $old $p;$out=Join-Path $testRoot 'old-output';Assert-RejectedWithMessageWithoutOutput {&$applyScript -DryRunJson $p -UseAllDryRunCandidates -OutputDir $out} $out '*已超过*' '过期 dry-run'
    $out=Join-Path $testRoot 'wide-age-output';Assert-RejectedWithMessageWithoutOutput {&$applyScript -DryRunJson $jsonPath -UseAllDryRunCandidates -MaxDryRunAgeHours 72 -OutputDir $out} $out '*1..24*' '超过 24 小时 freshness 配置'

    $badBool=$doc|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String;$badBool.coverageComplete='false';$p=Join-Path $testRoot 'bad-bool.json';Write-TestJsonPair $badBool $p;$out=Join-Path $testRoot 'bad-bool-output';Assert-RejectedWithMessageWithoutOutput {&$applyScript -DryRunJson $p -UseAllDryRunCandidates -OutputDir $out} $out '*JSON boolean*' '字符串 boolean'
    $badSchema=$doc|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String;$badSchema.schemaVersion=1;$p=Join-Path $testRoot 'bad-schema.json';Write-TestJsonPair $badSchema $p;$out=Join-Path $testRoot 'bad-schema-output';Assert-RejectedWithMessageWithoutOutput {&$applyScript -DryRunJson $p -UseAllDryRunCandidates -OutputDir $out} $out '*严格等于 2*' '旧 schema'

    $badLocal=$doc|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String;$badLocal.generatedAtLocal='not-a-date';$p=Join-Path $testRoot 'bad-local-time.json';Write-TestJsonPair $badLocal $p;$out=Join-Path $testRoot 'bad-local-time-output';Assert-RejectedWithMessageWithoutOutput {&$applyScript -DryRunJson $p -UseAllDryRunCandidates -OutputDir $out} $out '*generatedAtLocal*' '非法 generatedAtLocal 且报告对合法'
    $mismatchedLocal=$doc|ConvertTo-Json -Depth 100|ConvertFrom-Json -DateKind String;$mismatchedLocal.generatedAtLocal=([datetimeoffset]::Parse($mismatchedLocal.generatedAtUtc,[Globalization.CultureInfo]::InvariantCulture).AddMinutes(1).ToString('o',[Globalization.CultureInfo]::InvariantCulture));$p=Join-Path $testRoot 'mismatched-local-time.json';Write-TestJsonPair $mismatchedLocal $p;$out=Join-Path $testRoot 'mismatched-local-time-output';Assert-RejectedWithMessageWithoutOutput {&$applyScript -DryRunJson $p -UseAllDryRunCandidates -OutputDir $out} $out '*同一 instant*' 'generatedAtLocal 与 UTC instant 错配且报告对合法'

    $cDrive='C:\Codex-apply-manifest-should-not-be-created';$blocked=$false;try{&$applyScript -DryRunJson 'C:\forged-dry-run.json' -UseAllDryRunCandidates -OutputDir $cDrive|Out-Null}catch{$blocked=$true};Assert-True $blocked 'C 盘 DryRunJson 必须拒绝';Assert-True(-not(Test-Path -LiteralPath $cDrive))'测试不得创建 C 盘输出'
}finally{if(-not$KeepOutputs-and(Test-Path -LiteralPath $testRoot)){Assert-CanRemoveTestRoot $testRoot;Remove-Item -LiteralPath $testRoot -Recurse -Force}}
[pscustomobject]@{ok=$true}
