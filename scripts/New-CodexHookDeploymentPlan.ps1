[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][string]$FixtureSourceRoot,
    [Parameter(Mandatory)][string]$FixtureCodexHome,
    [Parameter(Mandatory)][ValidateSet('registration-repair', 'full')][string]$Mode,
    [string]$OutputDir = 'D:\Codex\projects\统一环境\reports\codex-hook-deployment-plan',
    [scriptblock]$EnvironmentReadValue
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\CodexHookPolicy.ps1')
. (Join-Path $PSScriptRoot 'lib\ReportArtifactPublisher.ps1')

$manifestFullPath = Assert-CodexHookDPath -Value $ManifestPath -Name 'ManifestPath'
$sourceRoot = Assert-CodexHookFixturePath -Path $FixtureSourceRoot -Name 'FixtureSourceRoot'
$codexHome = Assert-CodexHookFixturePath -Path $FixtureCodexHome -Name 'FixtureCodexHome'
if (
    (Test-CodexHookPathWithin -Path $sourceRoot -ParentPath $codexHome) -or
    (Test-CodexHookPathWithin -Path $codexHome -ParentPath $sourceRoot)
) {
    throw 'FixtureSourceRoot 与 FixtureCodexHome 必须是互不包含的独立根。'
}

$outputPath = Assert-CodexHookDPath -Value $OutputDir -Name 'OutputDir'
$allowedOutputRoots = @(
    'D:\Codex\projects\统一环境\reports\codex-hook-deployment-plan',
    'D:\Codex\projects\统一环境\reports\codex-hook-deployment-test'
)
if (-not @($allowedOutputRoots | Where-Object { Test-CodexHookPathWithin -Path $outputPath -ParentPath $_ }).Count) {
    throw 'OutputDir 不在固定 deployment plan 报告根。'
}
if ($outputPath.Substring(2).Contains(':')) { throw 'OutputDir 不得包含 ADS。' }

$manifestSnapshot = Read-CodexHookSafeUtf8FileSnapshot `
    -Path $manifestFullPath `
    -Name 'deployment manifest' `
    -AllowedExactPaths @($manifestFullPath)
Assert-CodexHookStrictJsonText -JsonText $manifestSnapshot.text
$manifest = $manifestSnapshot.text | ConvertFrom-Json -Depth 128 -ErrorAction Stop
[void](Assert-CodexHookManifest -Manifest $manifest)

$hooksRoot = Join-Path $codexHome 'hooks'
$registryPath = Join-Path $codexHome 'hooks.json'
$registrySnapshot = Read-CodexHookSafeUtf8FileSnapshot `
    -Path $registryPath `
    -Name 'fixture hook registry' `
    -AllowedExactPaths @($registryPath)
Assert-CodexHookStrictJsonText -JsonText $registrySnapshot.text
$registry = $registrySnapshot.text | ConvertFrom-Json -Depth 128 -ErrorAction Stop

$blockers = [Collections.Generic.List[object]]::new()
try {
    $desiredRegistry = Merge-CodexHookRegistry -Manifest $manifest -LiveRegistry $registry -Mode $Mode
} catch {
    $blockers.Add([pscustomobject][ordered]@{ code = 'registry-ownership-ambiguous' })
    $desiredRegistry = Copy-CodexHookJsonValue -Value $registry
}

$sourceFacts = [Collections.Generic.List[object]]::new()
$liveFacts = [Collections.Generic.List[object]]::new()
foreach ($file in @($manifest.files)) {
    $sourcePath = [IO.Path]::GetFullPath((Join-Path $sourceRoot ([string]$file.relativePath)))
    $targetPath = [IO.Path]::GetFullPath((Join-Path $hooksRoot ([string]$file.liveRelativePath)))
    if (-not (Test-CodexHookPathWithin -Path $sourcePath -ParentPath $sourceRoot)) { throw 'fixture source mapping 逃逸 source root。' }
    if (-not (Test-CodexHookPathWithin -Path $targetPath -ParentPath $hooksRoot)) { throw 'fixture target mapping 逃逸 hooks root。' }

    $sourceSnapshot = Get-CodexHookHandleBoundFileSnapshot -Path $sourcePath -Name 'fixture source' -AllowedExactPaths @($sourcePath)
    $sourceSha = if ($sourceSnapshot.probe.safeToRead) { Get-CodexHookBytesSha256 -Bytes ([byte[]]$sourceSnapshot.bytes) } else { $null }
    $sourceFacts.Add([pscustomobject][ordered]@{
        relativePath = [string]$file.relativePath
        path = $sourcePath
        exists = $sourceSnapshot.probe.exists -eq $true
        probeState = [string]$sourceSnapshot.probe.state
        sha256 = $sourceSha
    })

    $targetSnapshot = Get-CodexHookHandleBoundFileSnapshot -Path $targetPath -Name 'fixture target' -AllowedExactPaths @($targetPath)
    $targetSha = if ($targetSnapshot.probe.safeToRead) { Get-CodexHookBytesSha256 -Bytes ([byte[]]$targetSnapshot.bytes) } else { $null }
    $liveFacts.Add([pscustomobject][ordered]@{
        liveRelativePath = [string]$file.liveRelativePath
        path = $targetPath
        exists = $targetSnapshot.probe.exists -eq $true
        probeState = [string]$targetSnapshot.probe.state
        sha256 = $targetSha
    })
}

$environmentFacts = [Collections.Generic.List[object]]::new()
if ($Mode -ceq 'full') {
    if (@($manifest.environment).Count -gt 0 -and $null -eq $EnvironmentReadValue) {
        throw 'fixture full plan 必须注入 EnvironmentReadValue；禁止读取真实环境。'
    }
    foreach ($environment in @($manifest.environment)) {
        $environmentFacts.Add((Get-CodexHookEnvironmentValueFact `
            -Name ([string]$environment.name) `
            -Scope ([string]$environment.scope) `
            -ReadValue $EnvironmentReadValue `
            -Desired ([string]$environment.desired)))
    }
}

$inventory = [pscustomobject][ordered]@{
    targetProfile = 'codex-hook-fixture-v1'
    mappingIdentity = Get-CodexHookFixtureMappingIdentity -Manifest $manifest -SourceRoot $sourceRoot -CodexHome $codexHome
    manifestPath = $manifestFullPath
    manifestSha256 = [string]$manifestSnapshot.sha256
    sourceRoot = $sourceRoot
    codexHome = $codexHome
    hooksRoot = $hooksRoot
    registryPath = $registryPath
    registryBeforeSha256 = [string]$registrySnapshot.sha256
    sourceFiles = [object[]]$sourceFacts.ToArray()
    liveFiles = [object[]]$liveFacts.ToArray()
    environmentFacts = [object[]]$environmentFacts.ToArray()
    blockers = [object[]]$blockers.ToArray()
}

$document = New-CodexHookDeploymentPlanDocument `
    -Manifest $manifest `
    -Inventory $inventory `
    -DesiredRegistry $desiredRegistry `
    -Mode $Mode

Publish-JsonMarkdownArtifactPair `
    -Document $document `
    -OutputDir $outputPath `
    -JsonFileName 'plan.json' `
    -MarkdownFileName 'PLAN.md' `
    -RenderMarkdown {
        param($Document, $JsonSha256)
        @(
            '# Codex Hook 部署计划'
            ''
            "- 生成时间（UTC）：$($Document.generatedAtUtc)"
            "- 模式：$($Document.mode)"
            "- 可执行：$($Document.applyEligible)"
            "- 文件/registry 动作数：$(@($Document.actions).Count)"
            "- 环境动作数：$(@($Document.environmentActions).Count)"
            "- blocker reason codes：$(@($Document.sourceFacts.blockerReasonCodes) -join ',')"
            ''
            '本报告不包含 desired registry、raw registry command 或环境变量原值。'
        ) -join "`n"
    }
