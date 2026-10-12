[CmdletBinding(DefaultParameterSetName = 'Spec')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Spec')][string]$InputSpecPath,
    [Parameter(Mandatory, ParameterSetName = 'Paths')][string[]]$LiteralPath,
    [Parameter(ParameterSetName = 'Paths')][string]$Contains = '',
    [Parameter(ParameterSetName = 'Paths')][ValidateRange(1, 2147483647)][int]$StartLine = 1,
    [Parameter(ParameterSetName = 'Paths')][ValidateRange(1, 1000)][int]$MaxRows = 20,
    [Parameter(ParameterSetName = 'Paths')][ValidateRange(1, 2000)][int]$MaxValueChars = 200,
    [Parameter(ParameterSetName = 'Paths')][switch]$HttpLog,
    # Exact, case-sensitive ATX heading title; includes descendants and excludes fenced headings.
    [Parameter(ParameterSetName = 'Paths')][ValidateNotNullOrEmpty()][string]$MarkdownSection,
    [ValidateRange(512, 30000)][int]$MaxTotalBytes = 6000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$sensitiveName = '(?:set-cookie|cookie|authorization|proxy-authorization|x-api-key|x-auth-token|x-csrf-token|x-xsrf-token|(?:access|refresh|id|auth|session)[_-]?token|token|(?:client[_-]?)?secret|password|passwd|pwd|api[_-]?key|private[_-]?key|credentials?|session[_-]?id)'
$sensitiveAssignment = '(?i)(?<![\w?&#;%=-])' + $sensitiveName + '(?:\\*["''])?\s*[:=]\s*'

function Test-SensitiveField([string]$Field) {
    foreach ($part in $Field.Split('.')) {
        if ($part -match ('(?i)^' + $sensitiveName + '$')) { return $true }
    }
    return $false
}

function Protect-DiagnosticText([string]$Text) {
    $Text = [regex]::Replace($Text, '(?i)\b[a-z][a-z0-9+.-]*:(?:\\?/){2}[^\s<>"'']+', {
        param($urlMatch)
        $url = $urlMatch.Value.Replace('\/', '/')
        $url = [regex]::Replace($url, '(?i)([a-z][a-z0-9+.-]*://)[^/?#]*@', '$1[redacted]@')
        return [regex]::Replace($url, '([?&#;])([^?&#;=]+)=([^&#;]*)', {
            param($queryMatch)
            $key = [Uri]::UnescapeDataString($queryMatch.Groups[2].Value)
            $queryNames = '(?i)^(?:' + $sensitiveName + '|key|code|sig|signature|(?:x-amz|x-goog)-(?:credential|signature|security-token))$'
            if ($key -match $queryNames) { return $queryMatch.Groups[1].Value + $queryMatch.Groups[2].Value + '=[redacted]' }
            return $queryMatch.Value
        })
    })
    # Known header/credential assignments only. The rest of the logical line and
    # indented continuations are withheld; this is not a general secret detector.
    $assignment = '(' + $sensitiveAssignment + ')[^\r\n]*(?:\r?\n[ \t]+[^\r\n]*)*'
    return [regex]::Replace($Text, $assignment, '$1[redacted]')
}

function Limit-Value([object]$Value, [int]$Limit, [string]$Field = '') {
    if ($null -eq $Value) { return $null }
    if (Test-SensitiveField $Field) { return '[redacted]' }
    if ($Value -is [bool] -or $Value -is [ValueType]) { return $Value }
    if ($Value -isnot [string]) { return '[complex value omitted]' }
    $Value = Protect-DiagnosticText $Value
    if ($Value.Length -le $Limit) { return $Value }
    $length = $Limit
    if ([char]::IsHighSurrogate($Value[$length - 1])) { $length-- }
    return $Value.Substring(0, $length) + '[value clipped]'
}

function Get-Field([object]$Record, [string]$Field) {
    $value = $Record
    foreach ($key in $Field.Split('.')) {
        if ($value -isnot [System.Collections.IDictionary] -or -not $value.Contains($key)) { return $null }
        $value = $value[$key]
    }
    return $value
}

function Get-HttpDiagnostic([string]$Line, [int]$Limit) {
    # All output values are fixed events, bounded numbers or a parsed URL with
    # userinfo, query and fragment removed. No original message is returned.
    $curl = [regex]::Match($Line, '(?i)\bCurlError\s*[:=]?\s*(?<code>\d{1,4})\b')
    if ($curl.Success) {
        $event = [ordered]@{ event = 'curl-error'; curlCode = [int]$curl.Groups['code'].Value }
        $http = [regex]::Match($Line, '(?i)\bHTTP\s*[:=]?\s*(?<code>\d{1,3})\b')
        if ($http.Success) { $event.statusCode = [int]$http.Groups['code'].Value }
        return $event
    }
    if ($Line -match '(?i)\bCould not get headers\b') { return [ordered]@{ event = 'header-error' } }
    if ($Line -match '(?i)\block\b[^\r\n]*\btimed out\b') { return [ordered]@{ event = 'lock-timeout' } }
    if ($Line -match '(?i)\b(?:sha256|hash)\b[^\r\n]*\b(?:verification\s+failed|mismatch)\b') { return [ordered]@{ event = 'verification-error' } }
    $status = [regex]::Match($Line, '(?i)\bHTTP/[123](?:\.\d)?\s+(?<code>[1-5]\d{2})\b(?<tail>[^\r\n]*)')
    if ($status.Success) {
        $eventName = if ($status.Groups['code'].Value -eq '200' -and $status.Groups['tail'].Value -match '(?i)^\s+Connection established\b') { 'proxy-connect' } else { 'http-response' }
        return [ordered]@{ event = $eventName; statusCode = [int]$status.Groups['code'].Value }
    }
    $urlMatch = [regex]::Match($Line, '(?i)\bhttps?://[^\s<>"'']+')
    if ($urlMatch.Success) {
        $uri = $null
        if (-not [Uri]::TryCreate($urlMatch.Value, [UriKind]::Absolute, [ref]$uri) -or $uri.Host.Length -eq 0) { return $null }
        $builder = [UriBuilder]::new($uri)
        $builder.UserName = ''; $builder.Password = ''; $builder.Query = ''; $builder.Fragment = ''
        $event = [ordered]@{ event = 'http-url'; host = (Limit-Value $uri.DnsSafeHost $Limit); url = (Limit-Value $builder.Uri.AbsoluteUri $Limit) }
        $method = [regex]::Match($Line, '(?i)\b(GET|HEAD|POST|PUT|PATCH|DELETE|OPTIONS|CONNECT|TRACE)\s+https?://')
        if ($method.Success) { $event.event = 'http-request'; $event.method = $method.Groups[1].Value.ToUpperInvariant() }
        return $event
    }
    return $null
}

try {
    if ($PSCmdlet.ParameterSetName -eq 'Paths') {
        if ($HttpLog -and $PSBoundParameters.ContainsKey('MarkdownSection')) { throw 'Incompatible projection formats.' }
        $spec = @{ sources = @(foreach ($sourcePath in $LiteralPath) {
            $entry = @{ path = $sourcePath; format = $(if ($HttpLog) { 'http-log' } elseif ($PSBoundParameters.ContainsKey('MarkdownSection')) { 'markdown' } else { 'text' })
               contains = $Contains; startLine = $StartLine; maxRows = $MaxRows; maxValueChars = $MaxValueChars }
            if ($PSBoundParameters.ContainsKey('MarkdownSection')) { $entry.section = $MarkdownSection }
            $entry
        }) }
    }
    else {
        $specFile = Get-Item -LiteralPath $InputSpecPath
        if ($specFile.Length -gt 65536) { throw 'Invalid input spec.' }
        $spec = Get-Content -LiteralPath $InputSpecPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    }
    if ($spec -isnot [System.Collections.IDictionary] -or -not $spec.ContainsKey('sources')) { throw 'Invalid input spec.' }
    $inputs = @($spec.sources)
    if ($inputs.Count -lt 1 -or $inputs.Count -gt 64) { throw 'Invalid source count.' }
    $sources = [System.Collections.Generic.List[object]]::new()
    $pending = [System.Collections.Generic.List[object]]::new()
    foreach ($inputSource in $inputs) {
        if ($inputSource -isnot [System.Collections.IDictionary] -or
            -not $inputSource.ContainsKey('path') -or -not $inputSource.ContainsKey('format')) { throw 'Invalid source.' }
        $path = [string]$inputSource.path
        $format = [string]$inputSource.format
        if (-not [IO.Path]::IsPathFullyQualified($path) -or $path.Length -gt 512 -or $format -notin @('text', 'jsonl', 'http-log', 'markdown')) { throw 'Invalid source.' }
        $section = if ($inputSource.ContainsKey('section')) { $inputSource.section } else { $null }
        if ($format -ne 'markdown' -and $inputSource.ContainsKey('section')) { throw 'Section selection requires Markdown format.' }
        if ($format -eq 'markdown' -and ($section -isnot [string] -or [string]::IsNullOrWhiteSpace($section) -or $section.Length -gt 2000)) { throw 'Markdown requires an exact section title.' }
        $fields = @(if ($inputSource.ContainsKey('fields')) { $inputSource.fields })
        if ($format -eq 'jsonl' -and ($fields.Count -lt 1 -or $fields.Count -gt 32)) { throw 'JSONL requires fields.' }
        foreach ($field in $fields) {
            if ($field -isnot [string] -or $field.Length -lt 1 -or $field.Length -gt 128) { throw 'Invalid field.' }
        }
        $startLine = if ($inputSource.ContainsKey('startLine')) { [int]$inputSource.startLine } else { 1 }
        $maxRows = if ($inputSource.ContainsKey('maxRows')) { [int]$inputSource.maxRows } else { 20 }
        $maxValueChars = if ($inputSource.ContainsKey('maxValueChars')) { [int]$inputSource.maxValueChars } else { 200 }
        $contains = if ($inputSource.ContainsKey('contains')) { [string]$inputSource.contains } else { '' }
        if ($startLine -lt 1 -or $maxRows -lt 1 -or $maxRows -gt 1000 -or $maxValueChars -lt 1 -or $maxValueChars -gt 2000) { throw 'Invalid limits.' }
        $source = [ordered]@{
            path = $path; format = $format; status = 'read'; lineCount = 0
            matchedRows = 0; invalidJsonLines = 0; selectedRows = 0; emittedRows = 0
            omittedRows = 0; rows = [System.Collections.Generic.List[object]]::new()
        }
        if ($format -eq 'http-log') {
            $source.sensitiveRows = 0; $source.unrecognizedRows = 0; $source.replacementCharacterRows = 0
        }
        if ($format -eq 'markdown') {
            $source.sectionMatches = 0; $source.sectionStartLine = 0; $source.sectionEndLine = 0
        }
        $candidates = [System.Collections.Generic.List[object]]::new()
        $reader = $null
        $stream = $null
        $sensitiveContinuation = $false
        $pendingSensitiveValue = $false
        $insideSection = $false
        $sectionLevel = 0
        $fenceMarker = ''
        $fenceLength = 0
        try {
            # Active log writers and rotation may retain write/delete access.
            # This handle remains read-only and is owned by the outer finally.
            $stream = [IO.FileStream]::new($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            # Only HTTP logs may replace invalid UTF-8; their damaged lines are
            # withheld below. Do not guess alternate encodings for this mode.
            $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false, ($format -ne 'http-log')), ($format -ne 'http-log'), 1024, $true)
            while ($null -ne ($line = $reader.ReadLine())) {
                $source.lineCount++
                if ($format -eq 'markdown') {
                    $heading = $null
                    if ($fenceLength -gt 0) {
                        if ([regex]::IsMatch($line, '^ {0,3}' + [regex]::Escape($fenceMarker) + '{' + $fenceLength + ',}[ \t]*$')) {
                            $fenceLength = 0
                        }
                    }
                    else {
                        $fence = [regex]::Match($line, '^ {0,3}(?<fence>`{3,}|~{3,})(?<info>.*)$')
                        if ($fence.Success -and ($fence.Groups['fence'].Value[0] -eq '~' -or $fence.Groups['info'].Value.IndexOf('`') -lt 0)) {
                            $fenceMarker = $fence.Groups['fence'].Value.Substring(0, 1)
                            $fenceLength = $fence.Groups['fence'].Length
                        }
                        else { $heading = [regex]::Match($line, '^ {0,3}(?<marks>#{1,6})(?:[ \t]+(?<heading>.*))?$') }
                    }
                    if ($null -ne $heading -and $heading.Success) {
                        $level = $heading.Groups['marks'].Length
                        $title = [regex]::Replace($heading.Groups['heading'].Value, '[ \t]+#+[ \t]*$', '').Trim()
                        if ($insideSection -and $level -le $sectionLevel) {
                            $insideSection = $false
                            $source.sectionEndLine = $source.lineCount - 1
                        }
                        if ([string]::Equals($title, $section, [StringComparison]::Ordinal)) {
                            $source.sectionMatches++
                            if ($source.sectionMatches -eq 1) {
                                $insideSection = $true; $sectionLevel = $level
                                $source.sectionStartLine = $source.lineCount
                            }
                            else {
                                # A unique title cannot be proved until EOF. Never
                                # emit the first match after a later duplicate.
                                $insideSection = $false; $candidates.Clear(); $source.matchedRows = 0
                                $source.sectionStartLine = 0; $source.sectionEndLine = 0
                            }
                        }
                    }
                }
                if ($format -eq 'http-log' -and $line.IndexOf([char]0xFFFD) -ge 0) {
                    # Count all damaged rows before filtering; they cannot be
                    # classified or included in matchedRows. Withhold any folded
                    # continuation until the next unindented record boundary.
                    $source.replacementCharacterRows++
                    $sensitiveContinuation = $true
                    $pendingSensitiveValue = $false
                    continue
                }
                $record = $null
                $projectedText = $line
                if ($format -in @('text', 'http-log', 'markdown')) {
                    # Track preceding headers even outside the requested window.
                    $startsSensitive = [regex]::IsMatch($line, $sensitiveAssignment)
                    $continuedSensitive = $pendingSensitiveValue -or
                        ($sensitiveContinuation -and $line -match '^(?:[ \t]+|(?:\[[^\]\r\n]+\][ \t]*)+[ \t]{2,})')
                    if ($continuedSensitive) { $projectedText = '[redacted continuation]' }
                    $sensitiveContinuation = $startsSensitive -or $continuedSensitive
                    $pendingSensitiveValue = $startsSensitive -and [regex]::IsMatch($line, $sensitiveAssignment + '$')
                }
                if ($format -eq 'jsonl') {
                    try { $record = ConvertFrom-Json -InputObject $line -AsHashtable -ErrorAction Stop }
                    catch { $source.invalidJsonLines++; continue }
                }
                if (($format -eq 'markdown' -and -not $insideSection) -or $source.lineCount -lt $startLine -or
                    ($contains.Length -gt 0 -and $line.IndexOf($contains, [StringComparison]::OrdinalIgnoreCase) -lt 0)) { continue }
                $source.matchedRows++
                if ($format -eq 'http-log') {
                    if ($startsSensitive -or $continuedSensitive) { $source.sensitiveRows++; continue }
                    $httpEvent = Get-HttpDiagnostic $line $maxValueChars
                    if ($null -eq $httpEvent) { $source.unrecognizedRows++; continue }
                }
                if ($candidates.Count -ge $maxRows) { continue }
                $row = [ordered]@{ line = $source.lineCount }
                if ($format -in @('text', 'markdown')) { $row.text = Limit-Value $projectedText $maxValueChars }
                elseif ($format -eq 'http-log') {
                    foreach ($key in $httpEvent.Keys) { $row[$key] = $httpEvent[$key] }
                }
                else {
                    $values = [ordered]@{}
                    foreach ($field in $fields) { $values[$field] = Limit-Value (Get-Field $record $field) $maxValueChars $field }
                    $row.fields = $values
                }
                $candidates.Add($row)
            }
            if ($format -eq 'http-log' -and $source.replacementCharacterRows -gt 0) {
                $source.status = 'read-with-encoding-omissions'
            }
            if ($format -eq 'markdown') {
                if ($insideSection) { $source.sectionEndLine = $source.lineCount }
                if ($source.sectionMatches -eq 0) { $source.status = 'section-not-found' }
                elseif ($source.sectionMatches -gt 1) { $source.status = 'section-ambiguous' }
            }
        }
        catch {
            $source.status = 'read-failed'
            if ($format -eq 'markdown') {
                $candidates.Clear(); $source.matchedRows = 0
                $source.sectionStartLine = 0; $source.sectionEndLine = 0
            }
        }
        finally {
            try { if ($null -ne $reader) { $reader.Dispose() } }
            finally { if ($null -ne $stream) { $stream.Dispose() } }
        }
        $source.selectedRows = $candidates.Count
        $source.omittedRows = $source.matchedRows
        $sources.Add($source)
        $pending.Add($candidates)
    }

    $result = [ordered]@{ schemaVersion = 1; maxTotalBytes = $MaxTotalBytes; sources = $sources }
    # Reserve space for the full status/counter envelope before admitting any rows.
    $json = ConvertTo-Json -InputObject $result -Depth 12 -Compress
    if ([Text.Encoding]::UTF8.GetByteCount($json) + 2 -gt $MaxTotalBytes) { throw 'Source metadata exceeds output budget.' }
    $maxCandidates = ($pending | ForEach-Object { $_.Count } | Measure-Object -Maximum).Maximum
    for ($index = 0; $index -lt $maxCandidates; $index++) {
        for ($sourceIndex = 0; $sourceIndex -lt $sources.Count; $sourceIndex++) {
            if ($index -ge $pending[$sourceIndex].Count) { continue }
            $source = $sources[$sourceIndex]
            $source.rows.Add($pending[$sourceIndex][$index])
            $source.emittedRows++
            $source.omittedRows--
            $candidateJson = ConvertTo-Json -InputObject $result -Depth 12 -Compress
            if ([Text.Encoding]::UTF8.GetByteCount($candidateJson) + 2 -le $MaxTotalBytes) { $json = $candidateJson }
            else {
                $source.rows.RemoveAt($source.rows.Count - 1)
                $source.emittedRows--
                $source.omittedRows++
            }
        }
    }
    Write-Output $json
    if (@($sources | Where-Object { $_.status -ne 'read' -or $_.invalidJsonLines -gt 0 }).Count -gt 0) { exit 1 }
}
catch {
    # Input/parser diagnostics can contain raw material; expose only this bounded failure.
    Write-Output '{"schemaVersion":1,"status":"invalid-input-or-budget","nextAction":"Check the input spec and reduce the source batch."}'
    exit 2
}
