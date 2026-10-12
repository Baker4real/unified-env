[CmdletBinding()]
param([string]$EvidenceRoot = 'D:/agents/run-evidence/bounded-projection')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$runRoot = Join-Path $EvidenceRoot ((Get-Date -Format 'yyyyMMddTHHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $runRoot
$script = Join-Path $PSScriptRoot 'Read-BoundedProjection.ps1'
$pwsh = (Get-Command pwsh).Source
$checks = [System.Collections.Generic.List[object]]::new()
$sourceHashes = @{}

function Invoke-Case([string]$Name, [object[]]$Sources, [int]$Budget) {
    foreach ($source in $Sources) {
        if (-not $sourceHashes.ContainsKey($source.path) -and (Test-Path -LiteralPath $source.path -PathType Leaf)) {
            $sourceHashes[$source.path] = (Get-FileHash -LiteralPath $source.path).Hash
        }
    }
    $specPath = Join-Path $runRoot ($Name + '.spec.json')
    @{ sources = $Sources } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $specPath -Encoding utf8
    $start = [Diagnostics.ProcessStartInfo]::new($pwsh)
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $script, '-InputSpecPath', $specPath, '-MaxTotalBytes', [string]$Budget)) {
        $start.ArgumentList.Add($argument)
    }
    $child = [Diagnostics.Process]::Start($start)
    $stdoutTask = $child.StandardOutput.ReadToEndAsync()
    $stderrTask = $child.StandardError.ReadToEndAsync()
    $child.WaitForExit()
    $output = $stdoutTask.GetAwaiter().GetResult()
    $errors = $stderrTask.GetAwaiter().GetResult()
    $code = $child.ExitCode
    $child.Dispose()
    if ($errors.Length -gt 0) { throw "$Name wrote unexpected stderr; raw diagnostics are withheld." }
    if ([Text.Encoding]::UTF8.GetByteCount($output) -gt $Budget) { throw "$Name exceeded total output budget." }
    $json = $output.TrimEnd([char[]]"`r`n")
    $json | Set-Content -LiteralPath (Join-Path $runRoot ($Name + '.result.json')) -Encoding utf8
    return @{ result = ($json | ConvertFrom-Json -AsHashtable); json = $json; exitCode = $code }
}

$markdownPath = Join-Path $runRoot 'sections.md'
@(
    '# 指南',
    '章节外前言',
    '## 目标章节 ###',
    '正文',
    '### 子节',
    '子节正文',
    '#### 更深',
    '深层正文',
    '## 目标章节补充',
    '章节外后文',
    '# 最后',
    '文末'
) | Set-Content -LiteralPath $markdownPath -Encoding utf8
$section = Invoke-Case 'markdown-section-hierarchy' @(@{
    path = $markdownPath; format = 'markdown'; section = '目标章节'; maxRows = 50
}) 2500
if ($section.exitCode -ne 0) { throw 'Markdown section selection failed.' }
$sectionSource = $section.result.sources[0]
if ($sectionSource.status -ne 'read' -or $sectionSource.lineCount -ne 12 -or
    $sectionSource.sectionMatches -ne 1 -or $sectionSource.sectionStartLine -ne 3 -or $sectionSource.sectionEndLine -ne 8 -or
    $sectionSource.matchedRows -ne 6 -or $sectionSource.emittedRows -ne 6 -or $sectionSource.omittedRows -ne 0 -or
    ($sectionSource.rows.line -join ',') -ne '3,4,5,6,7,8' -or
    $sectionSource.rows[1].text -ne '正文' -or $section.json.Contains('章节外')) { throw 'Markdown section lost exact title, hierarchy, Chinese text or source lines.' }
$checks.Add(@{ name = 'markdown-exact-section-with-descendants-and-source-lines'; status = 'pass' })

$fencedMarkdownPath = Join-Path $runRoot 'fenced-sections.md'
@(
    '# Guide',
    '```md',
    '## 目标章节',
    '```',
    '## 目标章节',
    '正文',
    '````md',
    '## 截断伪标题',
    '```',
    '仍在长围栏内',
    '````',
    '~~~text',
    '## 目标章节',
    '~~~',
    '### 子节',
    '子节正文',
    '## 真正边界',
    '章节外后文'
) | Set-Content -LiteralPath $fencedMarkdownPath -Encoding utf8
$fencedSection = Invoke-Case 'markdown-fenced-headings' @(@{
    path = $fencedMarkdownPath; format = 'markdown'; section = '目标章节'; maxRows = 50
}) 3000
if ($fencedSection.exitCode -ne 0) { throw 'Markdown treated a fenced heading as a real section.' }
$fencedSource = $fencedSection.result.sources[0]
if ($fencedSource.sectionMatches -ne 1 -or $fencedSource.sectionStartLine -ne 5 -or $fencedSource.sectionEndLine -ne 16 -or
    $fencedSource.matchedRows -ne 12 -or $fencedSource.emittedRows -ne 12 -or
    ($fencedSource.rows.line -join ',') -ne '5,6,7,8,9,10,11,12,13,14,15,16' -or
    $fencedSection.json.Contains('章节外')) { throw 'Markdown fence length, delimiter or section boundary failed.' }
$checks.Add(@{ name = 'markdown-backtick-and-tilde-fences-preserve-section-boundaries'; status = 'pass' })

$wrongFormat = Invoke-Case 'markdown-section-requires-format' @(@{
    path = $markdownPath; format = 'text'; section = '目标章节'
}) 2500
if ($wrongFormat.exitCode -ne 2 -or $wrongFormat.result.status -ne 'invalid-input-or-budget' -or
    $wrongFormat.json.Contains('章节外')) { throw 'A section selector silently fell back to whole-file text.' }
$noSection = Invoke-Case 'markdown-requires-title' @(@{ path = $markdownPath; format = 'markdown' }) 512
if ($noSection.exitCode -ne 2 -or $noSection.result.status -ne 'invalid-input-or-budget') { throw 'Markdown allowed a missing section title.' }
$checks.Add(@{ name = 'markdown-requires-explicit-format-and-title'; status = 'pass' })

$duplicateMarkdownPath = Join-Path $runRoot 'duplicate-sections.md'
@(
    '# Guide',
    '## 重复章节',
    'FIRST_MATCH_MUST_NOT_RETURN',
    '### 子节',
    '子节正文',
    '## 重复章节',
    'SECOND_MATCH_MUST_NOT_RETURN'
) | Set-Content -LiteralPath $duplicateMarkdownPath -Encoding utf8
$duplicateSection = Invoke-Case 'markdown-ambiguous-section' @(@{
    path = $duplicateMarkdownPath; format = 'markdown'; section = '重复章节'; maxRows = 1
}) 1000
if ($duplicateSection.exitCode -ne 1 -or $duplicateSection.result.sources[0].status -ne 'section-ambiguous' -or
    $duplicateSection.result.sources[0].sectionMatches -ne 2 -or $duplicateSection.result.sources[0].lineCount -ne 7 -or
    $duplicateSection.result.sources[0].selectedRows -ne 0 -or $duplicateSection.result.sources[0].emittedRows -ne 0 -or
    $duplicateSection.result.sources[0].matchedRows -ne 0 -or $duplicateSection.result.sources[0].sectionStartLine -ne 0 -or
    $duplicateSection.result.sources[0].sectionEndLine -ne 0 -or $duplicateSection.json.Contains('MUST_NOT_RETURN')) { throw 'Ambiguous Markdown emitted an arbitrary match or stopped scanning at the row cap.' }
$missingSection = Invoke-Case 'markdown-missing-section' @(@{
    path = $fencedMarkdownPath; format = 'markdown'; section = '截断伪标题'
}) 1000
if ($missingSection.exitCode -ne 1 -or $missingSection.result.sources[0].status -ne 'section-not-found' -or
    $missingSection.result.sources[0].sectionMatches -ne 0 -or $missingSection.result.sources[0].rows.Count -ne 0 -or
    $missingSection.result.sources[0].matchedRows -ne 0 -or $missingSection.result.sources[0].sectionStartLine -ne 0 -or
    $missingSection.result.sources[0].sectionEndLine -ne 0) { throw 'A missing or fence-only Markdown title fell back to whole-file text.' }
$checks.Add(@{ name = 'markdown-missing-and-ambiguous-titles-fail-without-content'; status = 'pass' })

$directSectionOutput = @(& $pwsh -NoProfile -NonInteractive -File $script -LiteralPath $markdownPath -MarkdownSection '目标章节' -StartLine 4 -Contains '正文' -MaxRows 1 -MaxTotalBytes 1000)
$directSectionCode = $LASTEXITCODE
$directSectionJson = $directSectionOutput -join [Environment]::NewLine
if ($directSectionCode -ne 0) { throw 'Direct Markdown section entry failed.' }
$directSection = $directSectionJson | ConvertFrom-Json -AsHashtable
if ([Text.Encoding]::UTF8.GetByteCount($directSectionJson) + 2 -gt 1000 -or $directSection.sources.Count -ne 1 -or
    $directSection.sources[0].sectionStartLine -ne 3 -or $directSection.sources[0].sectionEndLine -ne 8 -or
    $directSection.sources[0].matchedRows -ne 3 -or $directSection.sources[0].emittedRows -ne 1 -or
    $directSection.sources[0].omittedRows -ne 2 -or $directSection.sources[0].rows[0].line -ne 4) { throw 'Direct Markdown selection lost original line window, filter or omission counts.' }
$checks.Add(@{ name = 'direct-markdown-section-composes-with-existing-window-filter-and-row-cap'; status = 'pass' })

$largeMarkdownPath = Join-Path $runRoot 'large-sections.md'
@(
    '# Guide',
    '## 预算章节',
    'Authorization:',
    'SYNTH_MARKDOWN_SECRET_184',
    '    SYNTH_MARKDOWN_FOLDED_295'
) | Set-Content -LiteralPath $largeMarkdownPath -Encoding utf8
1..20 | ForEach-Object { '中文正文' + ('测' * 60) } | Add-Content -LiteralPath $largeMarkdownPath -Encoding utf8
Add-Content -LiteralPath $largeMarkdownPath -Value '## 章节外' -Encoding utf8
$sectionBatch = Invoke-Case 'markdown-aggregate-budget' @(
    @{ path = $largeMarkdownPath; format = 'markdown'; section = '预算章节'; startLine = 4; maxRows = 50 },
    @{ path = $largeMarkdownPath; format = 'markdown'; section = '预算章节'; startLine = 4; maxRows = 50 }
) 1800
if ($sectionBatch.exitCode -ne 0 -or $sectionBatch.result.sources.Count -ne 2 -or $sectionBatch.json.Contains('SYNTH_')) { throw 'Markdown batch failed or exposed a sensitive continuation.' }
foreach ($source in $sectionBatch.result.sources) {
    if ($source.sectionStartLine -ne 2 -or $source.sectionEndLine -ne 25 -or $source.lineCount -ne 26 -or
        $source.matchedRows -ne 22 -or $source.emittedRows -lt 3 -or $source.omittedRows -lt 1 -or
        $source.emittedRows + $source.omittedRows -ne $source.matchedRows -or
        $source.rows[0].line -ne 4 -or $source.rows[0].text -ne '[redacted continuation]' -or
        $source.rows[1].text -ne '[redacted continuation]' -or -not $source.rows[2].text.StartsWith('中文正文')) { throw 'Markdown lost whole-batch byte budget, Chinese text, redaction before filtering or omission counts.' }
}
$checks.Add(@{ name = 'markdown-multiple-sources-share-byte-budget-redaction-and-counts'; status = 'pass'; outputBytes = [Text.Encoding]::UTF8.GetByteCount($sectionBatch.json) + 2; budget = 1800 })

$textPath = Join-Path $runRoot 'large.txt'
1..250 | ForEach-Object { ('line-{0:D3}:' -f $_) + ('x' * 500) } | Set-Content -LiteralPath $textPath -Encoding utf8
$jsonlPath = Join-Path $runRoot 'events.jsonl'
1..100 | ForEach-Object { @{ status = 'ok'; payload = @{ number = $_ }; secret = 'DO_NOT_RETURN_THIS_FIELD'; message = 'z' * 500 } | ConvertTo-Json -Depth 4 -Compress } | Set-Content -LiteralPath $jsonlPath -Encoding utf8
Add-Content -LiteralPath $jsonlPath -Value '{invalid-json SYNTH_PARSE_SECRET_296' -Encoding utf8
$beforeHashes = @((Get-FileHash -LiteralPath $textPath).Hash, (Get-FileHash -LiteralPath $jsonlPath).Hash)

$mixed = Invoke-Case 'aggregate-budget' @(
    @{ path = $textPath; format = 'text'; maxRows = 100; maxValueChars = 400 },
    @{ path = $jsonlPath; format = 'jsonl'; fields = @('status', 'payload.number'); maxRows = 100 }
) 1600
if ($mixed.exitCode -ne 1 -or $mixed.result.sources.Count -ne 2 -or
    $mixed.result.sources[0].lineCount -ne 250 -or $mixed.result.sources[1].invalidJsonLines -ne 1 -or
    $mixed.result.sources[0].omittedRows -lt 1 -or $mixed.result.sources[1].emittedRows -lt 1 -or
    $mixed.json.Contains('DO_NOT_RETURN_THIS_FIELD') -or $mixed.json.Contains('SYNTH_PARSE_SECRET_296')) { throw 'Aggregate budget/projection/parse status failed.' }
foreach ($source in $mixed.result.sources) {
    if ($source.matchedRows -ne $source.emittedRows + $source.omittedRows) { throw 'Projection count mismatch.' }
}
$checks.Add(@{ name = 'aggregate-budget-jsonl-field-selection'; status = 'pass'; outputBytes = [Text.Encoding]::UTF8.GetByteCount($mixed.json) + 2; budget = 1600 })

$window = Invoke-Case 'line-window' @(@{ path = $textPath; format = 'text'; startLine = 249; maxRows = 1; maxValueChars = 10 }) 1500
if ($window.exitCode -ne 0 -or $window.result.sources[0].rows[0].line -ne 249 -or
    $window.result.sources[0].emittedRows -ne 1 -or -not $window.json.Contains('[value clipped]')) { throw 'Line window failed.' }
$checks.Add(@{ name = 'line-window-value-limit'; status = 'pass' })

$missing = Invoke-Case 'missing-source' @(@{ path = (Join-Path $runRoot 'missing.txt'); format = 'text' }) 1500
if ($missing.exitCode -ne 1 -or $missing.result.sources[0].status -ne 'read-failed') { throw 'Missing source failed open.' }
$checks.Add(@{ name = 'missing-source-nonzero'; status = 'pass' })

$noFields = Invoke-Case 'missing-jsonl-fields' @(@{ path = $jsonlPath; format = 'jsonl' }) 512
if ($noFields.exitCode -ne 2 -or $noFields.result.status -ne 'invalid-input-or-budget') { throw 'JSONL allowed raw dump.' }
$checks.Add(@{ name = 'jsonl-requires-field-projection'; status = 'pass' })

$tooMany = Invoke-Case 'metadata-over-budget' @(1..12 | ForEach-Object { @{ path = $textPath; format = 'text' } }) 512
if ($tooMany.exitCode -ne 2 -or $tooMany.result.status -ne 'invalid-input-or-budget') { throw 'Metadata exceeded budget without failure.' }
$checks.Add(@{ name = 'metadata-over-budget-fails-bounded'; status = 'pass' })

$validJsonlPath = Join-Path $runRoot 'valid.jsonl'
'{"status":"ok","payload":{"hidden":"DO_NOT_RETURN_NESTED_OBJECT"}}' | Set-Content -LiteralPath $validJsonlPath -Encoding utf8
$oneField = Invoke-Case 'single-jsonl-field' @(@{ path = $validJsonlPath; format = 'jsonl'; fields = @('status') }) 1500
if ($oneField.exitCode -ne 0 -or $oneField.result.sources[0].rows[0].fields.status -ne 'ok') { throw 'Single field projection failed.' }
$complex = Invoke-Case 'complex-jsonl-field' @(@{ path = $validJsonlPath; format = 'jsonl'; fields = @('payload') }) 1500
if ($complex.exitCode -ne 0 -or $complex.json.Contains('DO_NOT_RETURN_NESTED_OBJECT') -or -not $complex.json.Contains('[complex value omitted]')) { throw 'Complex field exposed raw object.' }
$checks.Add(@{ name = 'single-and-complex-jsonl-fields'; status = 'pass' })

$unicodePath = Join-Path $runRoot 'unicode.txt'
$unicodeValue = ([string][char]0x4E2D + [char]::ConvertFromUtf32(0x1F680)) * 100
1..10 | ForEach-Object { $unicodeValue } | Set-Content -LiteralPath $unicodePath -Encoding utf8
$unicode = Invoke-Case 'unicode-byte-budget' @(@{ path = $unicodePath; format = 'text'; maxValueChars = 200 }) 1600
if ($unicode.exitCode -ne 0 -or $unicode.result.sources[0].emittedRows -lt 1 -or $unicode.result.sources[0].omittedRows -lt 1) { throw 'Unicode byte budget projection failed.' }
if (-not $unicode.result.sources[0].rows[0].text.StartsWith([string][char]0x4E2D + [char]::ConvertFromUtf32(0x1F680))) { throw 'CLI corrupted UTF-8 text.' }
$checks.Add(@{ name = 'unicode-byte-budget'; status = 'pass'; outputBytes = [Text.Encoding]::UTF8.GetByteCount($unicode.json) + 2; budget = 1600 })

# The direct path entry shares the same batch budget without creating a spec file.
$directDriver = Join-Path $runRoot 'direct-paths.ps1'
@'
param($Tool, $First, $Second)
$ErrorActionPreference = 'Stop'
& $Tool -LiteralPath @($First, $Second) -Contains 'line-' -StartLine 2 -MaxRows 2 -MaxValueChars 30 -MaxTotalBytes 1400
exit $LASTEXITCODE
'@ | Set-Content -LiteralPath $directDriver -Encoding utf8
$directOutput = @(& $pwsh -NoProfile -NonInteractive -File $directDriver $script $textPath $textPath)
$directCode = $LASTEXITCODE
$directJson = $directOutput -join [Environment]::NewLine
if ($directCode -ne 0) { throw 'Direct paths entry failed.' }
$direct = $directJson | ConvertFrom-Json -AsHashtable
if ([Text.Encoding]::UTF8.GetByteCount($directJson) + 2 -gt 1400 -or $direct.sources.Count -ne 2) { throw 'Direct paths bypassed aggregate budget.' }
foreach ($source in $direct.sources) {
    if ($source.path -ne $textPath -or $source.rows[0].line -ne 2 -or $source.matchedRows -ne 249 -or
        $source.emittedRows + $source.omittedRows -ne $source.matchedRows) { throw 'Direct paths lost identity or counts.' }
}
$checks.Add(@{ name = 'direct-paths-share-budget-and-source-metadata'; status = 'pass' })

# All diagnostic fixtures are synthetic and are exercised through the public CLI.
$headersPath = Join-Path $runRoot 'synthetic-headers.txt'
@(
    'function Add-Value { param($value) return $value + 1 }',
    '[INFO][HTTP] SeT-CoOkIe: session=SYNTH_COOKIE_ALPHA_428; Secure',
    '[DEBUG] Authorization: Bearer SYNTH_AUTH_ALPHA_529'
) | Set-Content -LiteralPath $headersPath -Encoding utf8
$headersHash = (Get-FileHash -LiteralPath $headersPath).Hash
$headers = Invoke-Case 'default-sensitive-headers' @(@{ path = $headersPath; format = 'text'; maxValueChars = 200 }) 2500
if ($headers.exitCode -ne 0 -or $headers.json.Contains('SYNTH_COOKIE_ALPHA_428') -or
    $headers.json.Contains('SYNTH_AUTH_ALPHA_529') -or
    $headers.result.sources[0].rows[0].text -ne 'function Add-Value { param($value) return $value + 1 }' -or
    -not $headers.result.sources[0].rows[1].text.Contains('[redacted]')) { throw 'Default text projection exposed a sensitive HTTP header or lost ordinary code.' }
if ((Get-FileHash -LiteralPath $headersPath).Hash -ne $headersHash) { throw 'Sensitive source changed during projection.' }
$checks.Add(@{ name = 'default-sensitive-headers-and-ordinary-code'; status = 'pass' })

$credentialsPath = Join-Path $runRoot 'synthetic-credentials.jsonl'
@(
    @{ message = '[native HTTP] headers={"cOoKiE":"session=SYNTH_JSON_COOKIE_630"}' },
    @{ message = 'response="{\"Authorization\":\"Bearer SYNTH_ESC_AUTH_741\"}"' },
    @{ message = "request`r`nCookie: session=SYNTH_MULTI_COOKIE_852`r`n    SYNTH_FOLDED_COOKIE_963`r`nHTTP/1.1 401" },
    @{ message = 'clientSecret = SYNTH_CLIENT_SECRET_174'; password = 'SYNTH_PASSWORD_285'; payload = @{ access_token = 'SYNTH_ACCESS_TOKEN_396'; retryCount = 2 } },
    @{ message = 'apiKey=SYNTH_API_KEY_407'; password = 123456 }
) | ForEach-Object { $_ | ConvertTo-Json -Depth 5 -Compress } | Set-Content -LiteralPath $credentialsPath -Encoding utf8
$credentialsHash = (Get-FileHash -LiteralPath $credentialsPath).Hash
$credentials = Invoke-Case 'jsonl-sensitive-values' @(@{
    path = $credentialsPath; format = 'jsonl'; fields = @('message', 'password', 'payload.access_token', 'payload.retryCount'); maxValueChars = 500
}) 5000
if ($credentials.exitCode -ne 0 -or $credentials.json.Contains('SYNTH_') -or
    $credentials.result.sources[0].rows[3].fields.password -ne '[redacted]' -or
    $credentials.result.sources[0].rows[3].fields.'payload.retryCount' -ne 2 -or
    $credentials.result.sources[0].rows[4].fields.password -ne '[redacted]' -or
    -not $credentials.result.sources[0].rows[2].fields.message.Contains('HTTP/1.1 401')) { throw 'JSONL message or selected credential field leaked, or safe status was lost.' }
if ((Get-FileHash -LiteralPath $credentialsPath).Hash -ne $credentialsHash) { throw 'JSONL source changed during projection.' }
$checks.Add(@{ name = 'jsonl-prefixed-escaped-multiline-and-selected-credentials'; status = 'pass' })

$urlsPath = Join-Path $runRoot 'synthetic-urls.txt'
@(
    'GET https://SYNTH_USER_518:SYNTH_URL_PASSWORD_629@example.test/api?page=2&access_token=SYNTH_QUERY_TOKEN_730&lang=en',
    'download https://example.test/file?X-Amz-Signature=SYNTH_QUERY_SIG_841&%61pi_key=SYNTH_ENCODED_KEY_952',
    'redirect https://example.test/cb#access_token=SYNTH_FRAGMENT_TOKEN_063&view=ok',
    ('prefix {"Authorization":"Bearer SYNTH_CROP_174' + ('Z' * 200) + '"}'),
    'https://example.test/docs?page=2&lang=en',
    'relay https://example.test/go?next=https://SYNTH_NESTED_USER_630:SYNTH_NESTED_PASSWORD_741@second.test/path'
) | Set-Content -LiteralPath $urlsPath -Encoding utf8
$urls = Invoke-Case 'url-and-before-clipping' @(@{ path = $urlsPath; format = 'text'; maxValueChars = 180 }) 3000
if ($urls.exitCode -ne 0 -or $urls.json.Contains('SYNTH_') -or
    -not $urls.result.sources[0].rows[0].text.Contains('page=2') -or
    -not $urls.result.sources[0].rows[0].text.Contains('lang=en') -or
    $urls.result.sources[0].rows[4].text -ne 'https://example.test/docs?page=2&lang=en') { throw 'URL identity/query masking or pre-clipping redaction failed.' }
$checks.Add(@{ name = 'url-userinfo-sensitive-query-fragment-and-before-clipping'; status = 'pass' })

$foldedPath = Join-Path $runRoot 'synthetic-folded.txt'
@(
    '[HTTP] Authorization: Bearer',
    '    SYNTH_TEXT_CONTINUATION_285',
    '"password":',
    '"SYNTH_TEXT_MULTILINE_396"',
    'ordinary documentation stays readable',
    'prefix {"Cookie":"SYNTH_CROPPED_COOKIE_407_and_more"}'
) | Set-Content -LiteralPath $foldedPath -Encoding utf8
$folded = Invoke-Case 'text-folding-before-window' @(@{ path = $foldedPath; format = 'text'; startLine = 2; maxValueChars = 26 }) 2500
if ($folded.exitCode -ne 0 -or $folded.json.Contains('SYNTH_') -or
    -not $folded.result.sources[0].rows[0].text.Contains('[redacted') -or
    -not $folded.result.sources[0].rows[3].text.StartsWith('ordinary documentation')) { throw 'Text continuations or clipped values exposed synthetic credentials.' }
$checks.Add(@{ name = 'text-folding-before-window-and-clipping'; status = 'pass' })

$httpPath = Join-Path $runRoot 'synthetic-nvidia-http.log'
@(
    '[2026-10-12 12:00:00] [Nv] HTTP/1.1 200 Connection established',
    '[Nv] Could not get headers',
    '[Nv] CurlError 102, HTTP 0',
    '[Nv] HTTP/1.1 206 Partial Content',
    '[Nv] Lock download-cache timed out',
    '[Nv] sha256 verification failed: SYNTH_HASH_DETAIL_518',
    '[Nv] GET https://SYNTH_HTTP_USER_629:SYNTH_HTTP_PASSWORD_730@download.example.test/driver.exe?token=SYNTH_HTTP_QUERY_841#SYNTH_HTTP_FRAGMENT_952',
    '[Nv] Set-Cookie: session=SYNTH_HTTP_COOKIE_063',
    '[Nv] payload=SYNTH_UNKNOWN_BODY_174',
    '[Nv] Authorization: Bearer SYNTH_HTTP_AUTH_285'
) | Set-Content -LiteralPath $httpPath -Encoding utf8
$http = Invoke-Case 'http-log-status-projection' @(@{ path = $httpPath; format = 'http-log'; maxRows = 20 }) 5000
if ($http.exitCode -ne 0) { throw 'Explicit HTTP projection is unavailable.' }
$httpSource = $http.result.sources[0]
if ($http.json.Contains('SYNTH_') -or $httpSource.emittedRows -ne 7 -or $httpSource.omittedRows -ne 3 -or
    $httpSource.unrecognizedRows -ne 1 -or $httpSource.sensitiveRows -ne 2 -or
    $httpSource.rows[0].event -ne 'proxy-connect' -or $httpSource.rows[0].statusCode -ne 200 -or
    $httpSource.rows[1].event -ne 'header-error' -or
    $httpSource.rows[2].event -ne 'curl-error' -or $httpSource.rows[2].curlCode -ne 102 -or $httpSource.rows[2].statusCode -ne 0 -or
    $httpSource.rows[3].event -ne 'http-response' -or $httpSource.rows[3].statusCode -ne 206 -or
    $httpSource.rows[4].event -ne 'lock-timeout' -or $httpSource.rows[5].event -ne 'verification-error' -or
    $httpSource.rows[6].method -ne 'GET' -or $httpSource.rows[6].host -ne 'download.example.test' -or
    $httpSource.rows[6].url -ne 'https://download.example.test/driver.exe') { throw 'HTTP allowlist exposed unknown content or lost NVIDIA status evidence.' }
$checks.Add(@{ name = 'http-log-nvidia-status-url-and-unknown-withholding'; status = 'pass' })

$directHttpDriver = Join-Path $runRoot 'direct-http.ps1'
@'
param($Tool, $Source)
$ErrorActionPreference = 'Stop'
& $Tool -LiteralPath @($Source, $Source) -HttpLog -MaxRows 20 -MaxTotalBytes 1500
exit $LASTEXITCODE
'@ | Set-Content -LiteralPath $directHttpDriver -Encoding utf8
$directHttpOutput = @(& $pwsh -NoProfile -NonInteractive -File $directHttpDriver $script $httpPath)
$directHttpCode = $LASTEXITCODE
$directHttpJson = $directHttpOutput -join [Environment]::NewLine
$directHttpJson | Set-Content -LiteralPath (Join-Path $runRoot 'direct-http.result.json') -Encoding utf8
$directHttp = $directHttpJson | ConvertFrom-Json -AsHashtable
if ($directHttpCode -ne 0 -or [Text.Encoding]::UTF8.GetByteCount($directHttpJson) + 2 -gt 1500 -or
    $directHttp.sources.Count -ne 2 -or $directHttpJson.Contains('SYNTH_')) { throw 'Direct HTTP paths bypassed safe projection or shared byte budget.' }
foreach ($source in $directHttp.sources) {
    if ($source.format -ne 'http-log' -or $source.emittedRows -lt 1 -or $source.matchedRows -ne 10 -or
        $source.sensitiveRows -ne 2 -or $source.unrecognizedRows -ne 1 -or
        $source.emittedRows + $source.omittedRows -ne $source.matchedRows) { throw 'HTTP projection count mismatch.' }
}
$checks.Add(@{ name = 'direct-http-paths-share-budget-and-withheld-counts'; status = 'pass'; outputBytes = [Text.Encoding]::UTF8.GetByteCount($directHttpJson) + 2; budget = 1500 })

$activePath = Join-Path $runRoot 'synthetic-active-http.log'
[IO.File]::WriteAllBytes($activePath, [IO.File]::ReadAllBytes($httpPath))
$sourceHashes[$activePath] = (Get-FileHash -LiteralPath $activePath).Hash
$writer = [IO.FileStream]::new($activePath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
try {
    $active = Invoke-Case 'active-writer-shared-read' @(
        @{ path = $activePath; format = 'http-log'; maxRows = 20 },
        @{ path = $activePath; format = 'http-log'; maxRows = 20 }
    ) 1500
    if ($active.exitCode -ne 0 -or -not $writer.CanWrite -or $active.json.Contains('SYNTH_')) { throw 'HTTP projection could not safely read a log with an active writer.' }
    foreach ($source in $active.result.sources) {
        if ($source.status -ne 'read' -or $source.lineCount -ne 10 -or $source.matchedRows -ne 10 -or
            $source.sensitiveRows -ne 2 -or $source.unrecognizedRows -ne 1 -or $source.emittedRows -lt 1 -or
            $source.emittedRows + $source.omittedRows -ne $source.matchedRows) { throw 'Active log projection lost read status, counts or budgeted rows.' }
    }
} finally { $writer.Dispose() }
if ((Get-FileHash -LiteralPath $activePath).Hash -ne $sourceHashes[$activePath]) { throw 'Active source changed during projection.' }
$checks.Add(@{ name = 'active-writer-read-only-shared-budget-and-counts'; status = 'pass'; outputBytes = [Text.Encoding]::UTF8.GetByteCount($active.json) + 2; budget = 1500 })

$encodingPath = Join-Path $runRoot 'synthetic-invalid-utf8.log'
$utf8 = [Text.UTF8Encoding]::new($false)
$encodingBytes = $utf8.GetBytes("[Nv] Could not get headers`r`n[Nv] HTTP/1.1 200 Connection established SYNTH_BAD_ENCODING_852=") +
    [byte[]]@(0xFF) + $utf8.GetBytes("SYNTH_BAD_ENCODING_963`r`n[Nv] CurlError 102, HTTP 0`r`n")
[IO.File]::WriteAllBytes($encodingPath, $encodingBytes)
$sourceHashes[$encodingPath] = (Get-FileHash -LiteralPath $encodingPath).Hash
$encodingWriter = [IO.FileStream]::new($encodingPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
try {
    $encoding = Invoke-Case 'http-log-partial-encoding' @(@{ path = $encodingPath; format = 'http-log' }) 1600
    $encodingSource = $encoding.result.sources[0]
    if ($encoding.exitCode -ne 1 -or -not $encodingWriter.CanWrite -or
        $encodingSource.status -ne 'read-with-encoding-omissions' -or $encodingSource.replacementCharacterRows -ne 1 -or
        $encodingSource.lineCount -ne 3 -or $encodingSource.matchedRows -ne 2 -or $encodingSource.emittedRows -ne 2 -or
        $encodingSource.omittedRows -ne 0 -or $encoding.json.Contains('SYNTH_') -or
        $encodingSource.rows[0].event -ne 'header-error' -or $encodingSource.rows[0].line -ne 1 -or
        $encodingSource.rows[1].event -ne 'curl-error' -or $encodingSource.rows[1].curlCode -ne 102 -or $encodingSource.rows[1].line -ne 3) { throw 'HTTP encoding recovery lost safe rows, exposed a damaged row, or hid incomplete coverage.' }
} finally { $encodingWriter.Dispose() }
foreach ($strictFormat in @('text', 'jsonl')) {
    $strictSource = @{ path = $encodingPath; format = $strictFormat }
    if ($strictFormat -eq 'jsonl') { $strictSource.fields = @('message') }
    $strict = Invoke-Case ('strict-encoding-' + $strictFormat) @($strictSource) 1600
    if ($strict.exitCode -ne 1 -or $strict.result.sources[0].status -ne 'read-failed' -or $strict.json.Contains('SYNTH_')) { throw 'Text or JSONL silently accepted invalid UTF-8.' }
}
$checks.Add(@{ name = 'http-log-partial-encoding-with-strict-text-jsonl'; status = 'pass'; outputBytes = [Text.Encoding]::UTF8.GetByteCount($encoding.json) + 2; budget = 1600 })

$afterHashes = @((Get-FileHash -LiteralPath $textPath).Hash, (Get-FileHash -LiteralPath $jsonlPath).Hash)
if (Compare-Object $beforeHashes $afterHashes) { throw 'Source changed during projection.' }
foreach ($sourcePath in $sourceHashes.Keys) {
    if ((Get-FileHash -LiteralPath $sourcePath).Hash -ne $sourceHashes[$sourcePath]) { throw 'A fixture source changed during projection.' }
}
$proof = @{ status = 'pass'; checks = $checks; evidenceRoot = $runRoot; sourcesUnchanged = $true; fixtureSourceCount = $sourceHashes.Count }
$proof | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runRoot 'proof.json') -Encoding utf8
$proof | ConvertTo-Json -Depth 8 -Compress
