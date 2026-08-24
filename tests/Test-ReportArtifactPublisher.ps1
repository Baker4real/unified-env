param(
    [string]$ProjectRoot = "D:\agents\projects\统一环境",
    [switch]$KeepOutputs
)

$ErrorActionPreference = "Stop"

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-CanRemoveTestRoot {
    param([Parameter(Mandatory)][string]$Path)

    Assert-True -Condition ([IO.Path]::IsPathFullyQualified($script:ProjectRoot)) -Message "ProjectRoot 必须是 D 盘绝对路径：$script:ProjectRoot"
    $fullProjectRoot = [IO.Path]::GetFullPath($script:ProjectRoot).TrimEnd("\", "/")
    Assert-True -Condition ([IO.Path]::GetPathRoot($fullProjectRoot) -ieq "D:\") -Message "ProjectRoot 必须位于 D:\：$fullProjectRoot"

    $fullReportsRoot = [IO.Path]::GetFullPath((Join-Path $fullProjectRoot "reports")).TrimEnd("\", "/")
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd("\", "/")
    $driveRoot = [IO.Path]::GetPathRoot($fullPath)
    $isUnderReports = $fullPath.StartsWith("$fullReportsRoot\", [StringComparison]::OrdinalIgnoreCase)
    Assert-True -Condition $isUnderReports -Message "测试输出目录必须位于项目 reports 下：$Path"

    $currentPath = $fullPath
    while ($null -ne $currentPath) {
        if (Test-Path -LiteralPath $currentPath) {
            $item = Get-Item -LiteralPath $currentPath -Force
            $isReparse = ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
            Assert-True -Condition (-not $isReparse) -Message "测试输出路径不能穿过 junction、symlink 或 reparse point：$currentPath"
        }

        if ($currentPath.TrimEnd("\", "/") -ieq $driveRoot.TrimEnd("\", "/")) {
            break
        }

        $parentPath = [IO.Directory]::GetParent($currentPath)
        if ($null -eq $parentPath) {
            break
        }
        $nextPath = $parentPath.FullName
        if ($nextPath.TrimEnd("\", "/") -ieq $currentPath.TrimEnd("\", "/")) {
            break
        }
        $currentPath = $nextPath
    }
}

function Assert-ProjectRootRejected {
    param(
        [Parameter(Mandatory)][string]$Candidate,
        [Parameter(Mandatory)][string]$ExpectedUntouchedPath,
        [Parameter(Mandatory)][string]$Message
    )

    $savedProjectRoot = $script:ProjectRoot
    try {
        $script:ProjectRoot = $Candidate
        $candidateTestRoot = Join-Path $Candidate "reports\report-artifact-publisher-test"
        $blocked = $false
        try {
            Assert-CanRemoveTestRoot -Path $candidateTestRoot
        } catch {
            $blocked = $true
        }

        Assert-True -Condition $blocked -Message $Message
        Assert-True -Condition (-not (Test-Path -LiteralPath $ExpectedUntouchedPath)) -Message "拒绝 ProjectRoot 时不得创建或删除越界内容：$ExpectedUntouchedPath"
    } finally {
        $script:ProjectRoot = $savedProjectRoot
    }
}

$publisherPath = Join-Path $ProjectRoot "scripts\lib\ReportArtifactPublisher.ps1"
$testRoot = Join-Path $ProjectRoot "reports\report-artifact-publisher-test"
$outputDir = Join-Path $testRoot "success"
$failureOutputDir = Join-Path $testRoot "render-failure"

$blockedCProjectRoot = "C:\Codex-report-artifact-project-root-$([guid]::NewGuid().ToString())"
Assert-ProjectRootRejected `
    -Candidate $blockedCProjectRoot `
    -ExpectedUntouchedPath $blockedCProjectRoot `
    -Message "测试没有拒绝 C 盘 ProjectRoot"

$blockedRelativeProjectRoot = "report-artifact-relative-$([guid]::NewGuid().ToString())"
$blockedRelativeFullPath = [IO.Path]::GetFullPath($blockedRelativeProjectRoot)
Assert-ProjectRootRejected `
    -Candidate $blockedRelativeProjectRoot `
    -ExpectedUntouchedPath $blockedRelativeFullPath `
    -Message "测试没有拒绝相对 ProjectRoot"

try {
    Assert-CanRemoveTestRoot -Path $testRoot
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }

    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

    $junctionProjectTarget = Join-Path $testRoot "project-root-target"
    $junctionProjectRoot = Join-Path $testRoot "project-root-link"
    $junctionProjectReports = Join-Path $junctionProjectTarget "reports"
    $junctionSentinel = Join-Path $junctionProjectTarget "sentinel.txt"
    New-Item -ItemType Directory -Path $junctionProjectReports -Force | Out-Null
    [IO.File]::WriteAllText($junctionSentinel, "untouched", [Text.UTF8Encoding]::new($false))
    New-Item -ItemType Junction -Path $junctionProjectRoot -Target $junctionProjectTarget | Out-Null
    $savedProjectRoot = $script:ProjectRoot
    try {
        $script:ProjectRoot = $junctionProjectRoot
        $junctionProjectTestRoot = Join-Path $junctionProjectRoot "reports\report-artifact-publisher-test"
        $junctionProjectBlocked = $false
        try {
            Assert-CanRemoveTestRoot -Path $junctionProjectTestRoot
        } catch {
            $junctionProjectBlocked = $_.Exception.Message -like "*reparse point*"
        }
        Assert-True $junctionProjectBlocked "测试没有拒绝穿过 junction 的 ProjectRoot"
        Assert-True (Test-Path -LiteralPath $junctionSentinel -PathType Leaf) "拒绝 junction ProjectRoot 时不得删除越界内容"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $junctionProjectReports "report-artifact-publisher-test"))) "拒绝 junction ProjectRoot 时不得创建越界内容"
    } finally {
        $script:ProjectRoot = $savedProjectRoot
        if (Test-Path -LiteralPath $junctionProjectRoot) {
            Remove-Item -LiteralPath $junctionProjectRoot -Force
        }
    }

    if (Test-Path -LiteralPath $publisherPath -PathType Leaf) {
        $savedErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            . $publisherPath
            $errorActionPreferenceAfterDotSource = [string]$ErrorActionPreference
        } finally {
            $ErrorActionPreference = $savedErrorActionPreference
        }
        Assert-True ($errorActionPreferenceAfterDotSource -ceq "Continue") "dot-source 发布器不得污染调用者 ErrorActionPreference"
    }

    $published = Publish-JsonMarkdownArtifactPair `
        -Document ([pscustomobject]@{ schemaVersion = 1; artifactType = "fixture" }) `
        -OutputDir $outputDir `
        -JsonFileName "fixture.json" `
        -MarkdownFileName "FIXTURE.md" `
        -RenderMarkdown { param($Document, $JsonSha256) "generationId=$($Document.generationId)`nsourceJsonSha256=$JsonSha256" }

    Assert-True ($published.generationId -match '^[0-9a-f-]{36}$') "缺少 generationId"
    Assert-True ((Test-JsonMarkdownArtifactPair -JsonPath $published.jsonPath -MarkdownPath $published.markdownPath).ok) "报告对必须通过校验"
    $publishedDocument = [IO.File]::ReadAllText($published.jsonPath) | ConvertFrom-Json
    $publishedMarkdown = [IO.File]::ReadAllText($published.markdownPath)
    $publishedFileHash = (Get-FileHash -LiteralPath $published.jsonPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-True ($publishedDocument.generationId -ceq $published.generationId) "JSON generationId 与发布结果不一致"
    Assert-True ($publishedFileHash -ceq $published.sourceJsonSha256) "发布结果 hash 与 JSON 文件字节不一致"
    Assert-True ($publishedMarkdown.StartsWith("---`ngenerationId: $($published.generationId)`nsourceJsonSha256: $publishedFileHash`n---`n")) "Markdown front matter 未记录正确的 id/hash"
    Assert-True (@(Get-ChildItem -LiteralPath $outputDir -Directory -Filter '.staging-*').Count -eq 0) "发布成功后遗留 staging"

    New-Item -ItemType Directory -Path $failureOutputDir -Force | Out-Null
    $oldJsonPath = Join-Path $failureOutputDir "fixture.json"
    $oldMarkdownPath = Join-Path $failureOutputDir "FIXTURE.md"
    $oldJson = '{"old":true}'
    $oldMarkdown = "old markdown"
    [IO.File]::WriteAllText($oldJsonPath, $oldJson, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($oldMarkdownPath, $oldMarkdown, [Text.UTF8Encoding]::new($false))

    $renderFailed = $false
    try {
        Publish-JsonMarkdownArtifactPair `
            -Document ([pscustomobject]@{ schemaVersion = 1; artifactType = "render-failure" }) `
            -OutputDir $failureOutputDir `
            -JsonFileName "fixture.json" `
            -MarkdownFileName "FIXTURE.md" `
            -RenderMarkdown { throw "renderer failed" } | Out-Null
    } catch {
        $renderFailed = $_.Exception.Message -like "*renderer failed*"
    }
    Assert-True $renderFailed "渲染器异常必须中止发布"
    Assert-True ([IO.File]::ReadAllText($oldJsonPath) -ceq $oldJson) "渲染失败后旧 JSON 被改变"
    Assert-True ([IO.File]::ReadAllText($oldMarkdownPath) -ceq $oldMarkdown) "渲染失败后旧 Markdown 被改变"
    Assert-True (@(Get-ChildItem -LiteralPath $failureOutputDir -Directory -Filter '.staging-*').Count -eq 0) "渲染失败后遗留 staging"

    $correctMarkdown = [IO.File]::ReadAllText($published.markdownPath)
    $wrongGenerationId = [guid]::NewGuid().ToString()
    $generationTamperedMarkdown = $correctMarkdown.Replace($published.generationId, $wrongGenerationId)
    [IO.File]::WriteAllText($published.markdownPath, $generationTamperedMarkdown, [Text.UTF8Encoding]::new($false))
    Assert-True (-not (Test-JsonMarkdownArtifactPair -JsonPath $published.jsonPath -MarkdownPath $published.markdownPath).ok) "generationId 错配必须校验失败"

    $wrongHash = '0' * 64
    if ($published.sourceJsonSha256 -ceq $wrongHash) {
        $wrongHash = '1' * 64
    }
    $hashTamperedMarkdown = $correctMarkdown.Replace($published.sourceJsonSha256, $wrongHash)
    [IO.File]::WriteAllText($published.markdownPath, $hashTamperedMarkdown, [Text.UTF8Encoding]::new($false))
    Assert-True (-not (Test-JsonMarkdownArtifactPair -JsonPath $published.jsonPath -MarkdownPath $published.markdownPath).ok) "sourceJsonSha256 错配必须校验失败"

    $blockedOutput = "C:\Codex-report-artifact-publisher-test-$([guid]::NewGuid().ToString())"
    $blocked = $false
    try {
        Publish-JsonMarkdownArtifactPair `
            -Document ([pscustomobject]@{ schemaVersion = 1; artifactType = "blocked-c-drive" }) `
            -OutputDir $blockedOutput `
            -JsonFileName "fixture.json" `
            -MarkdownFileName "FIXTURE.md" `
            -RenderMarkdown { param($Document, $JsonSha256) "blocked" } | Out-Null
    } catch {
        $blocked = $_.Exception.Message -like "*必须位于 D:\*"
    }
    Assert-True $blocked "发布器没有拒绝 C 盘 OutputDir"
    Assert-True (-not (Test-Path -LiteralPath $blockedOutput)) "测试不应在 C 盘创建输出目录"

    $junctionTarget = Join-Path $testRoot "reparse-target"
    $junctionPath = Join-Path $testRoot "reparse-link"
    New-Item -ItemType Directory -Path $junctionTarget -Force | Out-Null
    New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget | Out-Null
    try {
        $reparseBlocked = $false
        try {
            Publish-JsonMarkdownArtifactPair `
                -Document ([pscustomobject]@{ schemaVersion = 1; artifactType = "blocked-reparse" }) `
                -OutputDir (Join-Path $junctionPath "output") `
                -JsonFileName "fixture.json" `
                -MarkdownFileName "FIXTURE.md" `
                -RenderMarkdown { param($Document, $JsonSha256) "blocked" } | Out-Null
        } catch {
            $reparseBlocked = $_.Exception.Message -like "*reparse point*"
        }
        Assert-True $reparseBlocked "发布器没有拒绝含 reparse point 的 OutputDir 父链"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $junctionTarget "output"))) "reparse 拒绝前不应创建输出目录"
    } finally {
        if (Test-Path -LiteralPath $junctionPath) {
            Remove-Item -LiteralPath $junctionPath -Force
        }
    }
} finally {
    if (-not $KeepOutputs -and (Test-Path -LiteralPath $testRoot)) {
        Assert-CanRemoveTestRoot -Path $testRoot
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

[pscustomobject]@{
    ok = $true
}
