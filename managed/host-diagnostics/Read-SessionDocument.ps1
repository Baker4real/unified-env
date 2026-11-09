#Requires -Version 7.5
<#
.SYNOPSIS
按会话指纹去重读取静态文档，正文复用有界投影器。
.DESCRIPTION
StatePath 必须由调用者指定为本会话的 D 盘 JSON 文件。状态只登记实际
完整返回的选择，不保存正文；文件或选择变化以及 Refresh 都重新读取。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LiteralPath,
    [Parameter(Mandatory)][string]$StatePath,
    [string]$MarkdownSection,
    [ValidateRange(1, 2147483647)][int]$StartLine = 1,
    [ValidateRange(1, 1000)][int]$MaxRows = 20,
    [ValidateRange(1, 2000)][int]$MaxValueChars = 200,
    [ValidateRange(512, 30000)][int]$MaxTotalBytes = 6000,
    [switch]$Refresh
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false, $true)
[Console]::OutputEncoding = $utf8
$sourceHandle = $null
$failureCode = 'invalid-input'

function Get-TextHash([string]$Text) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes($Text))).ToLowerInvariant()
}

function Convert-Result([object]$Value) {
    ConvertTo-Json -InputObject $Value -Depth 15 -Compress
}

function Test-Fits([string]$Json) {
    # WriteLine 在 Windows 上追加 CRLF；把换行也计入预算。
    $utf8.GetByteCount($Json) + 2 -le $MaxTotalBytes
}

try {
    if (-not [IO.Path]::IsPathFullyQualified($LiteralPath) -or -not [IO.Path]::IsPathFullyQualified($StatePath)) { throw 'absolute-path-required' }
    $documentPath = [IO.Path]::GetFullPath($LiteralPath)
    $statePathFull = [IO.Path]::GetFullPath($StatePath)
    if ($documentPath.Length -gt 512 -or [IO.Path]::GetExtension($documentPath).ToLowerInvariant() -notin @('.md','.txt')) { throw 'static-document-required' }
    if (-not $statePathFull.StartsWith('D:\', [StringComparison]::OrdinalIgnoreCase) -or $statePathFull.Substring(2).Contains(':') -or
        [IO.Path]::GetExtension($statePathFull).ToLowerInvariant() -ne '.json' -or $statePathFull.Length -gt 512) { throw 'invalid-state-path' }
    if ([string]::Equals($documentPath, $statePathFull, [StringComparison]::OrdinalIgnoreCase)) { throw 'source-state-overlap' }
    # 只对状态写入路径拒绝重解析祖先，不把用户文件作为缓存目标。
    $ancestor = $statePathFull
    while ($ancestor) {
        if (Test-Path -LiteralPath $ancestor) {
            if (((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'state-reparse-path' }
        }
        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
    }
    $hasSection = $PSBoundParameters.ContainsKey('MarkdownSection')
    if ($hasSection -and ([string]::IsNullOrWhiteSpace($MarkdownSection) -or $MarkdownSection.Length -gt 2000)) { throw 'invalid-section' }
    $selection = [ordered]@{ startLine = $StartLine; maxRows = $MaxRows; maxValueChars = $MaxValueChars; maxTotalBytes = $MaxTotalBytes }
    # 标题也可能包含应被正文投影遮蔽的值；元数据只返回其指纹。
    if ($hasSection) { $selection.sectionSha256 = Get-TextHash $MarkdownSection }
    $selectionHash = Get-TextHash (Convert-Result $selection)
    $key = Get-TextHash ($documentPath.ToLowerInvariant() + "`n" + $selectionHash)

    $failureCode = 'invalid-state'
    $state = @{ schemaVersion = 1; documents = @() }
    $previousStateHash = $null
    if (Test-Path -LiteralPath $statePathFull) {
        $stateFile = Get-Item -LiteralPath $statePathFull
        if ($stateFile.PSIsContainer -or $stateFile.Length -gt 1048576) { throw 'invalid-state' }
        $stateText = [IO.File]::ReadAllText($statePathFull, $utf8)
        $previousStateHash = Get-TextHash $stateText
        $state = ConvertFrom-Json -InputObject $stateText -AsHashtable -DateKind String
        if ($state -isnot [Collections.IDictionary] -or $state.Count -ne 2 -or -not $state.Contains('schemaVersion') -or $state.schemaVersion -ne 1 -or
            -not $state.Contains('documents') -or $state.documents -isnot [array]) { throw 'invalid-state' }
        foreach ($record in $state.documents) {
            if ($record -isnot [Collections.IDictionary] -or $record.Count -ne 8 -or -not $record.Contains('key') -or $record.key -notmatch '^[a-f0-9]{64}$' -or
                -not $record.Contains('sha256') -or $record.sha256 -notmatch '^[a-f0-9]{64}$' -or -not $record.Contains('path') -or
                -not $record.Contains('selectionHash') -or -not $record.Contains('readAt') -or -not $record.Contains('firstLine') -or
                -not $record.Contains('lastLine') -or -not $record.Contains('emittedRows')) { throw 'invalid-state-record' }
            $parsedTime = [DateTimeOffset]::MinValue
            if ($record.path -isnot [string] -or -not [IO.Path]::IsPathFullyQualified($record.path) -or
                $record.selectionHash -isnot [string] -or $record.selectionHash -notmatch '^[a-f0-9]{64}$' -or
                $record.readAt -isnot [string] -or -not [DateTimeOffset]::TryParse($record.readAt, [ref]$parsedTime) -or
                $record.firstLine -isnot [long] -or $record.lastLine -isnot [long] -or $record.emittedRows -isnot [long] -or
                $record.firstLine -lt 1 -or $record.lastLine -lt $record.firstLine -or $record.emittedRows -lt 1 -or
                $record.emittedRows -gt ($record.lastLine - $record.firstLine + 1) -or
                $record.key -cne (Get-TextHash ($record.path.ToLowerInvariant() + "`n" + $record.selectionHash))) { throw 'invalid-state-record' }
        }
        if (@($state.documents.key | Select-Object -Unique).Count -ne $state.documents.Count) { throw 'duplicate-state-record' }
    }

    $failureCode = 'document-read-failed'
    # 同一只读句柄覆盖 hash 与投影期间，阻止内容更换后误记为已读。
    $sourceHandle = [IO.FileStream]::new($documentPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $documentHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($sourceHandle)).ToLowerInvariant()
    $result = [ordered]@{
        schemaVersion = 1; status = 'read'; maxTotalBytes = $MaxTotalBytes
        document = [ordered]@{ path = $documentPath; sha256 = $documentHash; byteLength = $sourceHandle.Length }
        selection = $selection
        state = [ordered]@{ path = $statePathFull; recorded = $false; readAt = $null }
    }
    $prior = @($state.documents | Where-Object { $_.key -eq $key -and $_.sha256 -eq $documentHash })
    if (-not $Refresh -and $prior.Count -eq 1) {
        $result.status = 'unchanged'
        $result.state.recorded = $true
        $result.state.readAt = $prior[0].readAt
        $result.lastProjection = [ordered]@{ firstLine = $prior[0].firstLine; lastLine = $prior[0].lastLine; emittedRows = $prior[0].emittedRows }
        $json = Convert-Result $result
        $failureCode = 'metadata-exceeds-budget'
        if (-not (Test-Fits $json)) { throw 'budget' }
        Write-Output $json
        exit 0
    }

    $failureCode = 'projection-failed'
    $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = $utf8; $start.StandardErrorEncoding = $utf8
    $arguments = @('-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot 'Read-BoundedProjection.ps1'),'-LiteralPath',$documentPath,
        '-StartLine',[string]$StartLine,'-MaxRows',[string]$MaxRows,'-MaxValueChars',[string]$MaxValueChars,'-MaxTotalBytes',[string]$MaxTotalBytes)
    if ($hasSection) { $arguments += @('-MarkdownSection',$MarkdownSection) }
    foreach ($argument in $arguments) { $start.ArgumentList.Add($argument) }
    $child = [Diagnostics.Process]::Start($start)
    try {
        $stdoutTask = $child.StandardOutput.ReadToEndAsync()
        $stderrTask = $child.StandardError.ReadToEndAsync()
        $child.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $projectionExit = $child.ExitCode
    }
    finally { $child.Dispose() }
    if ($stderr.Length -gt 0 -or $utf8.GetByteCount($stdout) -gt $MaxTotalBytes) { throw 'invalid-projection-output' }
    $projection = $stdout | ConvertFrom-Json -AsHashtable
    if (-not $projection.Contains('sources') -or @($projection.sources).Count -ne 1) { throw 'invalid-projection-output' }
    $result.source = $projection.sources[0]
    $source = $result.source
    # 单行超过 MaxValueChars 时投影器在行尾加 [value clipped]；这一行没有完整返回，不能登记为已读。
    $clippedRows = @($source.rows | Where-Object { $_.Contains('text') -and $_.text -is [string] -and $_.text.EndsWith('[value clipped]') }).Count
    $canRecord = $projectionExit -eq 0 -and $source.status -eq 'read' -and $source.selectedRows -gt 0 -and $source.emittedRows -eq $source.selectedRows -and $clippedRows -eq 0
    if ($projectionExit -ne 0) { $result.status = 'failed' }
    elseif ($source.emittedRows -lt $source.selectedRows -or $clippedRows -gt 0) { $result.status = 'incomplete' }
    $readAt = [DateTime]::UtcNow.ToString('o')
    if ($canRecord) { $result.state.recorded = $true; $result.state.readAt = $readAt }
    $json = Convert-Result $result
    while (-not (Test-Fits $json) -and @($source.rows).Count -gt 0) {
        $source.rows = @($source.rows | Select-Object -SkipLast 1)
        $source.emittedRows--; $source.omittedRows++
        $canRecord = $false; $result.state.recorded = $false; $result.state.readAt = $null
        if ($projectionExit -eq 0) { $result.status = 'incomplete' }
        $json = Convert-Result $result
    }
    $failureCode = 'metadata-exceeds-budget'
    if (-not (Test-Fits $json)) { throw 'budget' }
    if ($canRecord) {
        $failureCode = 'state-write-failed'
        $newRecord = [ordered]@{
            key = $key; path = $documentPath; sha256 = $documentHash; selectionHash = $selectionHash
            readAt = $readAt; firstLine = $source.rows[0].line; lastLine = $source.rows[-1].line; emittedRows = $source.emittedRows
        }
        $state.documents = @($state.documents | Where-Object { $_.key -ne $key }) + @($newRecord)
        $stateJson = Convert-Result $state
        if ($utf8.GetByteCount($stateJson) -gt 1048576) { throw 'state-too-large' }
        if (Test-Path -LiteralPath $statePathFull) {
            if ($null -eq $previousStateHash -or (Get-TextHash ([IO.File]::ReadAllText($statePathFull, $utf8))) -ne $previousStateHash) { throw 'state-changed' }
        }
        elseif ($null -ne $previousStateHash) { throw 'state-removed' }
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($statePathFull))
        $temporary = $statePathFull + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        try {
            [IO.File]::WriteAllText($temporary, $stateJson, $utf8)
            [IO.File]::Move($temporary, $statePathFull, $true)
        }
        finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
    }
    Write-Output $json
    if ($projectionExit -ne 0) { exit 1 }
}
catch {
    # 原始异常与文档内容不进入错误输出。
    Write-Output (Convert-Result ([ordered]@{ schemaVersion = 1; status = 'failed'; failureCode = $failureCode; recorded = $false }))
    exit 2
}
finally { if ($null -ne $sourceHandle) { $sourceHandle.Dispose() } }
