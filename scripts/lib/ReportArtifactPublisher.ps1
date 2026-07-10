$ErrorActionPreference = "Stop"

function Get-ReportSha256 {
    param([Parameter(Mandatory)][string]$Value)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
    $hash = [Security.Cryptography.SHA256]::HashData($bytes)
    return [Convert]::ToHexString($hash).ToLowerInvariant()
}

function Assert-TrustedReportOutputDirectory {
    param([Parameter(Mandatory)][string]$OutputDir)

    if (-not [IO.Path]::IsPathFullyQualified($OutputDir)) {
        throw "OutputDir 必须是 D 盘绝对路径：$OutputDir"
    }

    $fullPath = [IO.Path]::GetFullPath($OutputDir)
    if (-not ([IO.Path]::GetPathRoot($fullPath) -ieq "D:\")) {
        throw "OutputDir 必须位于 D:\：$fullPath"
    }

    $currentPath = $fullPath
    while (-not (Test-Path -LiteralPath $currentPath)) {
        $parentPath = [IO.Directory]::GetParent($currentPath)
        if ($null -eq $parentPath) {
            break
        }
        $currentPath = $parentPath.FullName
    }

    while ($null -ne $currentPath) {
        $item = Get-Item -LiteralPath $currentPath -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "OutputDir 父链不得包含 reparse point：$($item.FullName)"
        }

        $parentPath = [IO.Directory]::GetParent($item.FullName)
        if ($null -eq $parentPath) {
            break
        }
        $currentPath = $parentPath.FullName
    }

    return $fullPath
}

function Assert-ReportArtifactFileName {
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$ParameterName
    )

    if ([string]::IsNullOrWhiteSpace($FileName) -or
        [IO.Path]::IsPathFullyQualified($FileName) -or
        [IO.Path]::GetFileName($FileName) -cne $FileName) {
        throw "$ParameterName 必须是单个文件名：$FileName"
    }
}

function Test-JsonMarkdownArtifactPair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JsonPath,
        [Parameter(Mandatory)][string]$MarkdownPath
    )

    try {
        $jsonText = [IO.File]::ReadAllText($JsonPath)
        $document = $jsonText | ConvertFrom-Json
        $generationId = [string]$document.generationId
        $jsonSha256 = Get-ReportSha256 -Value $jsonText
        $markdownText = [IO.File]::ReadAllText($MarkdownPath)

        $frontMatterMatch = [regex]::Match(
            $markdownText,
            '\A---\r?\n(?<frontMatter>.*?)\r?\n---(?:\r?\n|\z)',
            [Text.RegularExpressions.RegexOptions]::Singleline
        )
        if (-not $frontMatterMatch.Success) {
            throw "Markdown 缺少 front matter"
        }

        $frontMatter = $frontMatterMatch.Groups['frontMatter'].Value
        $generationMatch = [regex]::Match($frontMatter, '(?m)^generationId:\s*(?<value>[^\r\n]+)\s*$')
        $hashMatch = [regex]::Match($frontMatter, '(?m)^sourceJsonSha256:\s*(?<value>[0-9a-fA-F]{64})\s*$')
        if ([string]::IsNullOrWhiteSpace($generationId) -or -not $generationMatch.Success -or -not $hashMatch.Success) {
            throw "报告对缺少 generationId 或 sourceJsonSha256"
        }

        $markdownGenerationId = $generationMatch.Groups['value'].Value.Trim()
        $markdownJsonSha256 = $hashMatch.Groups['value'].Value.Trim().ToLowerInvariant()
        if ($markdownGenerationId -cne $generationId) {
            throw "JSON 与 Markdown 的 generationId 不一致"
        }
        if ($markdownJsonSha256 -cne $jsonSha256) {
            throw "Markdown 的 sourceJsonSha256 与 JSON 内容不一致"
        }

        return [pscustomobject]@{
            ok = $true
            generationId = $generationId
            sourceJsonSha256 = $jsonSha256
        }
    } catch {
        return [pscustomobject]@{
            ok = $false
            error = $_.Exception.Message
        }
    }
}

function Publish-JsonMarkdownArtifactPair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Document,
        [Parameter(Mandatory)][string]$OutputDir,
        [Parameter(Mandatory)][string]$JsonFileName,
        [Parameter(Mandatory)][string]$MarkdownFileName,
        [Parameter(Mandatory)][scriptblock]$RenderMarkdown
    )

    Assert-ReportArtifactFileName -FileName $JsonFileName -ParameterName "JsonFileName"
    Assert-ReportArtifactFileName -FileName $MarkdownFileName -ParameterName "MarkdownFileName"
    if ($JsonFileName -ieq $MarkdownFileName) {
        throw "JSON 与 Markdown 文件名必须不同"
    }

    $outputPath = Assert-TrustedReportOutputDirectory -OutputDir $OutputDir
    New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
    $outputPath = Assert-TrustedReportOutputDirectory -OutputDir $outputPath

    $generationId = [guid]::NewGuid().ToString()
    $Document | Add-Member -MemberType NoteProperty -Name generationId -Value $generationId -Force

    $jsonText = $Document | ConvertTo-Json -Depth 100
    $jsonSha256 = Get-ReportSha256 -Value $jsonText
    $stagingPath = Join-Path $outputPath ".staging-$([guid]::NewGuid().ToString())"
    $stagingCreated = $false

    try {
        New-Item -ItemType Directory -Path $stagingPath | Out-Null
        $stagingCreated = $true

        $stagingJsonPath = Join-Path $stagingPath $JsonFileName
        $stagingMarkdownPath = Join-Path $stagingPath $MarkdownFileName
        [IO.File]::WriteAllText($stagingJsonPath, $jsonText, [Text.UTF8Encoding]::new($false))

        $renderedMarkdown = & $RenderMarkdown $Document $jsonSha256
        if ($null -eq $renderedMarkdown) {
            $markdownBody = ""
        } elseif ($renderedMarkdown -is [string]) {
            $markdownBody = $renderedMarkdown
        } else {
            $markdownBody = @($renderedMarkdown) -join [Environment]::NewLine
        }

        $markdownText = "---`ngenerationId: $generationId`nsourceJsonSha256: $jsonSha256`n---`n$markdownBody"
        [IO.File]::WriteAllText($stagingMarkdownPath, $markdownText, [Text.UTF8Encoding]::new($false))

        $stagingValidation = Test-JsonMarkdownArtifactPair -JsonPath $stagingJsonPath -MarkdownPath $stagingMarkdownPath
        if (-not $stagingValidation.ok) {
            throw "staging 报告对校验失败：$($stagingValidation.error)"
        }

        $jsonPath = Join-Path $outputPath $JsonFileName
        $markdownPath = Join-Path $outputPath $MarkdownFileName
        [IO.File]::Move($stagingJsonPath, $jsonPath, $true)
        [IO.File]::Move($stagingMarkdownPath, $markdownPath, $true)

        return [pscustomobject]@{
            generationId = $generationId
            sourceJsonSha256 = $jsonSha256
            jsonPath = $jsonPath
            markdownPath = $markdownPath
        }
    } finally {
        if ($stagingCreated -and (Test-Path -LiteralPath $stagingPath)) {
            Remove-Item -LiteralPath $stagingPath -Recurse -Force
        }
    }
}
