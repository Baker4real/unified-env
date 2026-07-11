. (Join-Path $PSScriptRoot "EnvPathSafety.ps1")
. (Join-Path $PSScriptRoot "ReportArtifactPublisher.ps1")

function Assert-TrustedReportInputFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ParameterName
    )

    Assert-EnvSafeAbsolutePath -Path $Path -FactName $ParameterName
    try {
        $fullPath = [IO.Path]::GetFullPath($Path)
        if ([IO.Path]::GetPathRoot($fullPath) -ine "D:\") {
            throw "$ParameterName 必须位于 D:\：$Path"
        }
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf -ErrorAction Stop)) {
            throw "$ParameterName 不存在或不是文件：$fullPath"
        }

        $current = $fullPath
        while (-not [string]::IsNullOrWhiteSpace($current)) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$ParameterName 不能穿过 junction、symlink 或 reparse point：$current"
            }
            $root = [IO.Path]::GetPathRoot($current)
            if ($current.TrimEnd('\', '/') -ieq $root.TrimEnd('\', '/')) { break }
            $parent = [IO.Directory]::GetParent($current.TrimEnd('\', '/'))
            if ($null -eq $parent) { throw "$ParameterName 父链无法完整验证：$current" }
            $current = $parent.FullName
        }
        return $fullPath
    } catch {
        throw "$ParameterName 元数据或父链验证失败：$($_.Exception.Message)"
    }
}

function Get-TrustedReportInputPair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JsonPath,
        [AllowEmptyString()][string]$MarkdownPath,
        [Parameter(Mandatory)][string]$DefaultMarkdownFileName,
        [Parameter(Mandatory)][string]$JsonParameterName,
        [Parameter(Mandatory)][string]$MarkdownParameterName
    )

    $trustedJsonPath = Assert-TrustedReportInputFile -Path $JsonPath -ParameterName $JsonParameterName
    $effectiveMarkdownPath = if ([string]::IsNullOrWhiteSpace($MarkdownPath)) {
        Join-Path ([IO.Path]::GetDirectoryName($trustedJsonPath)) $DefaultMarkdownFileName
    } else {
        $MarkdownPath
    }
    $trustedMarkdownPath = Assert-TrustedReportInputFile -Path $effectiveMarkdownPath -ParameterName $MarkdownParameterName
    $pair = Test-JsonMarkdownArtifactPair -JsonPath $trustedJsonPath -MarkdownPath $trustedMarkdownPath
    if (-not $pair.ok) {
        throw "$JsonParameterName/$MarkdownParameterName 报告对校验失败：$($pair.error)"
    }
    [pscustomobject]@{ jsonPath = $trustedJsonPath; markdownPath = $trustedMarkdownPath; generationId = $pair.generationId; sourceJsonSha256 = $pair.sourceJsonSha256 }
}
