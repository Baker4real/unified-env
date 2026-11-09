#Requires -Version 7.5
[CmdletBinding()]
param([string]$EvidenceRoot = 'D:/agents/run-evidence/session-document')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$runRoot = Join-Path $EvidenceRoot ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($runRoot)
$entry = Join-Path $PSScriptRoot 'Read-SessionDocument.ps1'
$checks = [Collections.Generic.List[object]]::new()

function Assert-True([bool]$Value, [string]$Message) {
    if (-not $Value) { throw $Message }
}

function Invoke-Read([string]$Name, [string]$Document, [string]$State, [string[]]$Arguments = @(), [int]$Budget = 6000) {
    $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = $utf8
    $start.StandardErrorEncoding = $utf8
    foreach ($argument in (@('-NoProfile','-NonInteractive','-File',$entry,'-LiteralPath',$Document,'-StatePath',$State,'-MaxTotalBytes',[string]$Budget) + $Arguments)) {
        $start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $exitCode = $process.ExitCode
    }
    finally { $process.Dispose() }
    [IO.File]::WriteAllText((Join-Path $runRoot ($Name + '.stdout.json')), $stdout, $utf8)
    Assert-True ($stderr.Length -eq 0) "$Name emitted unexpected stderr; raw diagnostics withheld."
    Assert-True ($utf8.GetByteCount($stdout) -le $Budget) "$Name exceeded the complete UTF-8 output budget."
    $result = $stdout | ConvertFrom-Json -AsHashtable
    return @{ result = $result; exitCode = $exitCode; text = $stdout; bytes = $utf8.GetByteCount($stdout) }
}

$document = Join-Path $runRoot 'guide.md'
$state = Join-Path $runRoot 'read-state.json'
[IO.File]::WriteAllText($document, "# 指南`n## 目标`n正文第一版`n## 其他`n不应返回`n", $utf8)
$first = Invoke-Read 'first-section' $document $state @('-MarkdownSection','目标')
Assert-True ($first.exitCode -eq 0 -and $first.result.status -eq 'read' -and $first.result.state.recorded) 'First successful selection must return content and register its fingerprint.'
Assert-True (($first.result.source.rows.line -join ',') -eq '2,3' -and $first.text.Contains('正文第一版') -and -not $first.text.Contains('不应返回')) 'Section projection must preserve exact source lines and only emit the selected section.'
Assert-True (Test-Path -LiteralPath $state -PathType Leaf) 'Successful projection must persist session state.'
$checks.Add(@{ name = 'first-section-records-only-emitted-selection'; status = 'pass' })

$stateBefore = [IO.File]::ReadAllText($state, $utf8)
$stateModified = [IO.File]::GetLastWriteTimeUtc($state)
$unchanged = Invoke-Read 'unchanged-section' $document $state @('-MarkdownSection','目标')
Assert-True ($unchanged.exitCode -eq 0 -and $unchanged.result.status -eq 'unchanged' -and $unchanged.result.lastProjection.firstLine -eq 2 -and $unchanged.result.lastProjection.lastLine -eq 3) 'An unchanged selection must return only its prior evidence pointer.'
Assert-True (-not $unchanged.text.Contains('正文第一版') -and -not $unchanged.result.Contains('source') -and $unchanged.bytes -lt $first.bytes) 'Unchanged output must omit the source body.'
Assert-True ([IO.File]::ReadAllText($state, $utf8) -ceq $stateBefore -and [IO.File]::GetLastWriteTimeUtc($state) -eq $stateModified) 'Repeated reads must not rewrite session state.'
Assert-True (-not $stateBefore.Contains('正文第一版') -and -not $stateBefore.Contains('目标')) 'Session state must store fingerprints and line pointers, not document text or section titles.'
$checks.Add(@{ name = 'unchanged-selection-is-compact-and-does-not-write'; status = 'pass' })

$badRecord = $stateBefore | ConvertFrom-Json -AsHashtable
$badRecord.documents[0].emittedRows = 0
$badState = Join-Path $runRoot 'invalid-record.json'
$badText = $badRecord | ConvertTo-Json -Depth 8 -Compress
[IO.File]::WriteAllText($badState, $badText, $utf8)
$bad = Invoke-Read 'invalid-record' $document $badState @('-MarkdownSection','目标')
Assert-True ($bad.exitCode -ne 0 -and $bad.result.status -eq 'failed') 'Invalid stored evidence must never suppress a document read as unchanged.'
Assert-True ([IO.File]::ReadAllText($badState, $utf8) -ceq $badText) 'Invalid session state must be preserved for inspection.'
$checks.Add(@{ name = 'invalid-stored-evidence-is-not-treated-as-read'; status = 'pass' })

$originalMtime = [IO.File]::GetLastWriteTimeUtc($document)
[IO.File]::WriteAllText($document, "# 指南`n## 目标`n正文第二版`n## 其他`n不应返回`n", $utf8)
[IO.File]::SetLastWriteTimeUtc($document, $originalMtime)
$changed = Invoke-Read 'content-change-same-mtime' $document $state @('-MarkdownSection','目标')
Assert-True ($changed.exitCode -eq 0 -and $changed.result.status -eq 'read' -and $changed.text.Contains('正文第二版') -and $changed.result.document.sha256 -ne $first.result.document.sha256) 'A content change with identical mtime and length must force a new read.'
$checks.Add(@{ name = 'content-hash-detects-change-with-identical-mtime'; status = 'pass' })

$differentSelection = Invoke-Read 'selection-change' $document $state @('-MarkdownSection','目标','-MaxRows','1')
Assert-True ($differentSelection.exitCode -eq 0 -and $differentSelection.result.status -eq 'read' -and $differentSelection.result.source.rows.Count -eq 1 -and $differentSelection.result.source.rows[0].line -eq 2) 'Changing the selected window must produce that window instead of an unchanged pointer.'
$checks.Add(@{ name = 'selection-change-is-read-independently'; status = 'pass' })

$refreshed = Invoke-Read 'refresh' $document $state @('-MarkdownSection','目标','-Refresh')
Assert-True ($refreshed.exitCode -eq 0 -and $refreshed.result.status -eq 'read' -and $refreshed.text.Contains('正文第二版')) 'Refresh must re-emit an otherwise cached selection.'
$checks.Add(@{ name = 'refresh-reemits-cached-selection'; status = 'pass' })

$stateBeforeFailure = [IO.File]::ReadAllText($state, $utf8)
$missingSection = Invoke-Read 'missing-section' $document $state @('-MarkdownSection','不存在')
Assert-True ($missingSection.exitCode -ne 0 -and $missingSection.result.status -eq 'failed' -and -not $missingSection.result.state.recorded -and $missingSection.result.source.status -eq 'section-not-found') 'A missing section must expose projection failure without registering a read.'
Assert-True ([IO.File]::ReadAllText($state, $utf8) -ceq $stateBeforeFailure) 'A failed projection must not change existing successful evidence.'
$checks.Add(@{ name = 'failed-projection-preserves-state'; status = 'pass' })

$missingState = Join-Path $runRoot 'missing-document-state.json'
$missing = Invoke-Read 'missing-document' (Join-Path $runRoot 'missing.md') $missingState
Assert-True ($missing.exitCode -ne 0 -and $missing.result.status -eq 'failed' -and -not (Test-Path -LiteralPath $missingState)) 'An unreadable document must not create state.'
$checks.Add(@{ name = 'unreadable-document-is-not-registered'; status = 'pass' })

$corruptState = Join-Path $runRoot 'corrupt-state.json'
[IO.File]::WriteAllText($corruptState, '{invalid-json', $utf8)
$corrupt = Invoke-Read 'corrupt-state' $document $corruptState
Assert-True ($corrupt.exitCode -ne 0 -and $corrupt.result.failureCode -eq 'invalid-state' -and [IO.File]::ReadAllText($corruptState, $utf8) -ceq '{invalid-json') 'A malformed state file must fail safely and remain intact.'
$checks.Add(@{ name = 'malformed-state-fails-without-overwrite'; status = 'pass' })

$largeDocument = Join-Path $runRoot 'large.txt'
$largeState = Join-Path $runRoot 'large-state.json'
[IO.File]::WriteAllText($largeDocument, ((1..8 | ForEach-Object { [string]$_ + ('汉字' * 150) }) -join "`n"), $utf8)
$limited = Invoke-Read 'bounded-complete-envelope' $largeDocument $largeState @('-MaxRows','8','-MaxValueChars','500') 2500
Assert-True ($limited.exitCode -eq 0 -and $limited.result.status -eq 'incomplete' -and -not $limited.result.state.recorded -and $limited.result.source.emittedRows -lt $limited.result.source.selectedRows) 'Budget-trimmed content must remain explicitly incomplete and unrecorded.'
Assert-True (-not (Test-Path -LiteralPath $largeState)) 'Unreturned selected rows must not be cached as read.'
$limitedAgain = Invoke-Read 'bounded-repeat' $largeDocument $largeState @('-MaxRows','8','-MaxValueChars','500') 2500
Assert-True ($limitedAgain.result.status -eq 'incomplete') 'An incomplete read must not turn into unchanged on repetition.'
$checks.Add(@{ name = 'complete-envelope-budget-does-not-cache-omitted-rows'; status = 'pass' })

$clippedDocument = Join-Path $runRoot 'clipped.txt'
$clippedState = Join-Path $runRoot 'clipped-state.json'
[IO.File]::WriteAllText($clippedDocument, "short line`n" + ('x' * 50) + "`n", $utf8)
$clipped = Invoke-Read 'clipped-line' $clippedDocument $clippedState @('-MaxValueChars','10')
Assert-True ($clipped.exitCode -eq 0 -and $clipped.result.status -eq 'incomplete' -and -not $clipped.result.state.recorded -and -not (Test-Path -LiteralPath $clippedState)) 'A clipped line must stay incomplete and unrecorded.'
$clippedAgain = Invoke-Read 'clipped-repeat' $clippedDocument $clippedState @('-MaxValueChars','10')
Assert-True ($clippedAgain.result.status -eq 'incomplete') 'A clipped selection must not turn into unchanged on repetition.'
$checks.Add(@{ name = 'clipped-line-is-not-registered'; status = 'pass' })

$tinyState = Join-Path $runRoot 'tiny-state.json'
$tiny = Invoke-Read 'metadata-budget' $document $tinyState @() 512
Assert-True ($tiny.exitCode -ne 0 -and $tiny.result.status -eq 'failed' -and -not (Test-Path -LiteralPath $tinyState)) 'An envelope that cannot fit must fail within the same budget and not create state.'
$checks.Add(@{ name = 'metadata-overflow-has-bounded-failure'; status = 'pass' })

$emptyDocument = Join-Path $runRoot 'empty.txt'
$emptyState = Join-Path $runRoot 'empty-state.json'
[IO.File]::WriteAllText($emptyDocument, '', $utf8)
$empty = Invoke-Read 'empty-document' $emptyDocument $emptyState
Assert-True ($empty.exitCode -eq 0 -and -not $empty.result.state.recorded -and $empty.result.source.emittedRows -eq 0 -and -not (Test-Path -LiteralPath $emptyState)) 'No emitted content must not create an already-read assertion.'
$checks.Add(@{ name = 'zero-emitted-rows-are-not-registered'; status = 'pass' })

$sensitiveDocument = Join-Path $runRoot 'redaction.txt'
$sensitiveState = Join-Path $runRoot 'redaction-state.json'
[IO.File]::WriteAllText($sensitiveDocument, "ordinary line`ntoken=fixture-private-value`n", $utf8)
$redacted = Invoke-Read 'redaction' $sensitiveDocument $sensitiveState
Assert-True ($redacted.exitCode -eq 0 -and $redacted.text.Contains('[redacted]') -and -not $redacted.text.Contains('fixture-private-value')) 'The wrapper must preserve the existing projector credential redaction.'
Assert-True (-not [IO.File]::ReadAllText($sensitiveState, $utf8).Contains('fixture-private-value')) 'Session state must not copy sensitive source text.'
$checks.Add(@{ name = 'existing-redaction-is-preserved'; status = 'pass' })

$sensitiveHeading = Join-Path $runRoot 'redacted-heading.md'
$headingState = Join-Path $runRoot 'heading-state.json'
[IO.File]::WriteAllText($sensitiveHeading, "# 文档`n## token=fixture-heading-secret`nordinary content`n", $utf8)
$heading = Invoke-Read 'selection-redaction' $sensitiveHeading $headingState @('-MarkdownSection','token=fixture-heading-secret')
Assert-True ($heading.exitCode -eq 0 -and -not $heading.text.Contains('fixture-heading-secret') -and $heading.text.Contains('ordinary content')) 'Selection metadata must not reintroduce text redacted by the projector.'
$checks.Add(@{ name = 'selection-metadata-does-not-bypass-redaction'; status = 'pass' })

$results = @($checks | ForEach-Object { [ordered]@{ name = $_.name; passed = $_.status -eq 'pass' } })
[pscustomobject]@{ status = 'passed'; cases = $results.Count; results = $results; evidenceDirectory = $runRoot } | ConvertTo-Json -Depth 8 -Compress
