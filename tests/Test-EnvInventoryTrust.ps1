param(
    [string]$ProjectRoot = "D:\Codex\projects\统一环境"
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

$libraryPath = Join-Path $ProjectRoot "scripts\lib\EnvInventoryTrust.ps1"
if (Test-Path -LiteralPath $libraryPath -PathType Leaf) {
    . $libraryPath
}

$metadata = @{
    "C:\Windows\System32" = [pscustomobject]@{ exists = $true; isReparsePoint = $false; reparseTarget = $null }
    "D:\Tools" = [pscustomobject]@{ exists = $true; isReparsePoint = $false; reparseTarget = $null }
    "D:\Missing" = [pscustomobject]@{ exists = $false; isReparsePoint = $false; reparseTarget = $null }
}
$resolver = {
    param([string]$Path)

    $normalizedPath = $Path.TrimEnd("\", "/")
    if (-not $metadata.ContainsKey($normalizedPath)) {
        throw "Unexpected metadata path: $Path"
    }
    return $metadata[$normalizedPath]
}.GetNewClosure()

$previousSystemRoot = $env:SystemRoot
try {
    $env:SystemRoot = "C:\Windows"

    $scope = New-PathScopeRecord -Source user -RawValue "%SystemRoot%\System32;D:\Tools;d:\tools\" -DotNetValue "%SystemRoot%\System32;D:\Tools;d:\tools\" -ReadErrors @() -MetadataResolver $resolver
    Assert-True -Condition ([bool]$scope.complete) -Message "合法 scope 应完整"
    Assert-True -Condition ($scope.entries[0].expandedPath -ceq "C:\Windows\System32") -Message "环境变量必须展开"
    Assert-True -Condition ($scope.duplicates.Count -eq 1) -Message "比较必须忽略大小写和尾分隔符"
    Assert-True -Condition ($scope.rawValueSha256 -cmatch "^[0-9a-f]{64}$") -Message "raw PATH 只能保存 SHA-256"
    Assert-True -Condition (-not ($scope.PSObject.Properties.Name -contains "rawValue")) -Message "scope 不得暴露 raw PATH"
    foreach ($entry in $scope.entries) {
        $actualFields = @($entry.PSObject.Properties.Name)
        $expectedFields = @("index", "rawPath", "expandedPath", "expansionStatus", "exists", "drive", "isReparsePoint", "reparseTarget")
        Assert-True -Condition (($actualFields -join ",") -ceq ($expectedFields -join ",")) -Message "PATH entry 字段必须固定"
    }

    $mismatch = New-PathScopeRecord -Source machine -RawValue "D:\Tools" -DotNetValue "D:\Missing" -ReadErrors @() -MetadataResolver $resolver
    Assert-True -Condition (-not [bool]$mismatch.complete) -Message "注册表/.NET PATH 不一致时 scope 必须不完整"
    Assert-True -Condition ($mismatch.missingPathCleanupCandidates.Count -eq 0) -Message "不完整 scope 不得给出 missing cleanup 建议"

    $expansionFailure = New-PathScopeRecord -Source user -RawValue "%CODEX_TEST_UNDEFINED_ROOT%\bin" -DotNetValue "%CODEX_TEST_UNDEFINED_ROOT%\bin" -ReadErrors @() -MetadataResolver $resolver
    Assert-True -Condition (-not [bool]$expansionFailure.complete) -Message "PATH 展开失败时 scope 必须不完整"
    Assert-True -Condition ($expansionFailure.entries[0].expansionStatus -eq "failed") -Message "PATH 展开失败必须显式记录"
    Assert-True -Condition ($null -eq $expansionFailure.entries[0].drive) -Message "PATH 展开失败时 drive 必须为 null"
    Assert-True -Condition ($expansionFailure.missingPathCleanupCandidates.Count -eq 0) -Message "展开失败时不得给出 missing cleanup 建议"

    $readFailure = New-PathScopeRecord -Source user -RawValue "D:\Missing" -DotNetValue "D:\Missing" -ReadErrors @("HKCU PATH read failed") -MetadataResolver $resolver
    Assert-True -Condition (-not [bool]$readFailure.complete) -Message "PATH 读取失败时 scope 必须不完整"
    Assert-True -Condition ($readFailure.readStatus -eq "error") -Message "PATH 读取失败必须显式标记 readStatus=error"
    Assert-True -Condition ($readFailure.missingPathCleanupCandidates.Count -eq 0) -Message "读取失败时不得给出 missing cleanup 建议"

    $rootResolver = {
        param([string]$Path)
        [pscustomobject]@{ exists = $true; isReparsePoint = $false; reparseTarget = $null }
    }
    $driveRoots = New-PathScopeRecord -Source process -RawValue "C:\;C:" -DotNetValue "C:\;C:" -ReadErrors @() -MetadataResolver $rootResolver
    Assert-True -Condition ($driveRoots.duplicates.Count -eq 0) -Message "驱动器根 C:\ 与驱动器相对路径 C: 不得误判为重复"

    $hashScope = New-PathScopeRecord -Source process -RawValue "abc" -DotNetValue "abc" -ReadErrors @() -MetadataResolver $rootResolver
    Assert-True -Condition ($hashScope.rawValueSha256 -ceq "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad") -Message "rawValueSha256 必须是 raw PATH 的真实 SHA-256"
} finally {
    $env:SystemRoot = $previousSystemRoot
}

$pythonProbeJson = '{"executable":"D:\\hermes-data\\hermes-agent\\venv-new\\Scripts\\python.exe","prefix":"D:\\hermes-data\\hermes-agent\\venv-new","basePrefix":"D:\\hermes-data\\.local\\python\\pythoncore-3.14-64"}'
$pythonRuntime = ConvertFrom-PythonRuntimeProbe -Json $pythonProbeJson
Assert-True -Condition ([bool]$pythonRuntime.succeeded) -Message "严格 Python JSON probe 应解析成功"

$originMetadata = {
    param([string]$Path)

    if ($Path -ieq "D:\Reparse\tool.exe") {
        return [pscustomobject]@{ isReparsePoint = $true; reparseTarget = "D:\Vendor\tool.exe" }
    }
    return [pscustomobject]@{ isReparsePoint = $false; reparseTarget = $null }
}
$decisionArgs = @{
    ProjectRoots = @("D:\hermes-data\hermes-agent")
    SharedRoots = @("D:\hermes-data\.npm-global", "D:\Shared")
    VendorRoots = @("D:\Vendor")
    SystemInstallerRoots = @("C:\Program Files", "C:\Program Files (x86)", "C:\Windows")
    MetadataResolver = $originMetadata
    LauncherProbeSucceeded = $true
}

$pythonDecision = Get-ToolOriginDecision -LauncherPath "D:\hermes-data\.npm-global\python.exe" -RuntimePath $pythonRuntime.executable -RuntimePrefix $pythonRuntime.prefix -RuntimeBasePrefix $pythonRuntime.basePrefix -RuntimeProbeSucceeded @decisionArgs
Assert-True -Condition ($pythonDecision.launcher.originClass -eq "shared-tool") -Message "Python launcher owner 应由 launcher 路径独立判定"
Assert-True -Condition ($pythonDecision.runtime.originClass -eq "project-local-env") -Message "Python runtime owner 应由 sys.executable 独立判定"
Assert-True -Condition ($pythonDecision.originClass -eq "project-local-env") -Message "Python 最终归属应以 runtime 为准"
Assert-True -Condition ([bool]$pythonDecision.requiresManualReview) -Message "项目本地 Python runtime 必须人工审查"
Assert-True -Condition ($pythonDecision.resolutionScope -eq "process") -Message "工具解析作用域必须明确为 process"

$twoLayerOwner = Get-ToolOriginDecision -LauncherPath "D:\Shared\python.exe" -RuntimePath "D:\hermes-data\hermes-agent\custom-env\Scripts\python.exe" -RuntimePrefix "D:\hermes-data\hermes-agent\custom-env" -RuntimeBasePrefix "D:\Shared\python-base" -RuntimeProbeSucceeded @decisionArgs
Assert-True -Condition ($twoLayerOwner.runtime.originClass -eq "project-local-env") -Message "prefix/basePrefix 虚拟环境证据与项目 owner 证据同时成立时应判为 project-local-env"
$missingVirtualEvidence = Get-ToolOriginDecision -LauncherPath "D:\Shared\python.exe" -RuntimePath "D:\hermes-data\hermes-agent\custom-env\Scripts\python.exe" -RuntimePrefix "D:\hermes-data\hermes-agent\custom-env" -RuntimeBasePrefix "D:\hermes-data\hermes-agent\custom-env" -RuntimeProbeSucceeded @decisionArgs
Assert-True -Condition ($missingVirtualEvidence.runtime.originClass -eq "unknown") -Message "prefix=basePrefix 时不得仅凭项目路径判为 project-local-env"

$classificationCases = @(
    @{ path = "D:\hermes-data\hermes-agent\venv-new\Scripts\python.exe"; expected = "project-local-env" }
    @{ path = "D:\Reparse\tool.exe"; expected = "unknown" }
    @{ path = "D:\Vendor\tool.exe"; expected = "vendor-runtime" }
    @{ path = "C:\Program Files\Vendor\tool.exe"; expected = "system-installer" }
    @{ path = "D:\Shared\tool.exe"; expected = "shared-tool" }
    @{ path = "D:\Unclassified\tool.exe"; expected = "unknown" }
)
foreach ($case in $classificationCases) {
    $decision = Get-ToolOriginDecision -LauncherPath $case.path -RuntimePath $null @decisionArgs
    Assert-True -Condition ($decision.originClass -eq $case.expected) -Message "归属分类错误: $($case.path) => $($decision.originClass)"
}

$priorityDecision = Get-ToolOriginDecision -LauncherPath "D:\hermes-data\hermes-agent\venv-new\Scripts\python.exe" -RuntimePath $null -ProjectRoots @("D:\hermes-data\hermes-agent") -SharedRoots @("D:\hermes-data") -VendorRoots @("D:\hermes-data\hermes-agent") -SystemInstallerRoots @() -MetadataResolver $originMetadata
Assert-True -Condition ($priorityDecision.originClass -eq "project-local-env") -Message "项目本地根必须高于 vendor/shared/unknown 优先级"

$ordinaryProjectTool = Get-ToolOriginDecision -LauncherPath "D:\hermes-data\hermes-agent\tools\python.exe" -RuntimePath $null @decisionArgs
Assert-True -Condition ($ordinaryProjectTool.originClass -eq "unknown") -Message "仅位于项目根不能被误判为 project-local-env"

$projectReparseMetadata = {
    param([string]$Path)
    [pscustomobject]@{ isReparsePoint = $true; reparseTarget = "D:\Shared\tool.exe" }
}
$projectReparse = Get-ToolOriginDecision -LauncherPath "D:\hermes-data\hermes-agent\venv-new\Scripts\python.exe" -RuntimePath $null -ProjectRoots @("D:\hermes-data\hermes-agent") -SharedRoots @("D:\Shared") -VendorRoots @() -SystemInstallerRoots @() -MetadataResolver $projectReparseMetadata
Assert-True -Condition ($projectReparse.originClass -eq "project-local-env") -Message "reparse 风险证据不得丢失项目 owner 事实"
Assert-True -Condition ([bool]$projectReparse.requiresManualReview) -Message "项目内 reparse 必须人工审查"

$launcherReparseRuntimeShared = Get-ToolOriginDecision -LauncherPath "D:\Reparse\tool.exe" -RuntimePath "D:\Shared\tool.exe" -RuntimeProbeSucceeded @decisionArgs
Assert-True -Condition ($launcherReparseRuntimeShared.originClass -eq "shared-tool") -Message "最终归属仍应反映 runtime owner"
Assert-True -Condition ([bool]$launcherReparseRuntimeShared.requiresManualReview) -Message "launcher/runtime 任一 reparse 都必须人工审查"

foreach ($manualClassPath in @("D:\Vendor\tool.exe", "C:\Program Files\Vendor\tool.exe")) {
    $manualDecision = Get-ToolOriginDecision -LauncherPath $manualClassPath -RuntimePath $null @decisionArgs
    Assert-True -Condition ([bool]$manualDecision.requiresManualReview) -Message "$($manualDecision.originClass) 必须人工审查"
}

$failedSharedProbe = Get-ToolOriginDecision -LauncherPath "D:\Shared\tool.exe" -RuntimePath $null -ProjectRoots @() -SharedRoots @("D:\Shared") -VendorRoots @() -SystemInstallerRoots @() -MetadataResolver $originMetadata
Assert-True -Condition ($failedSharedProbe.originClass -eq "unknown") -Message "shared allowlist 没有成功 probe 时归属必须降级为 unknown"
Assert-True -Condition ([bool]$failedSharedProbe.requiresManualReview) -Message "shared allowlist probe 失败时必须人工审查"

$invalidProbe = ConvertFrom-PythonRuntimeProbe -Json "$pythonProbeJson`nnoise"
$invalidDecision = Get-ToolOriginDecision -LauncherPath "D:\hermes-data\.npm-global\python.exe" -RuntimePath $null -RuntimeProbeFailed @decisionArgs
Assert-True -Condition (-not [bool]$invalidProbe.succeeded) -Message "非严格 Python JSON 必须失败"
Assert-True -Condition ($invalidDecision.originClass -eq "unknown") -Message "Python probe 失败时归属必须为 unknown"
Assert-True -Condition ([bool]$invalidDecision.requiresManualReview) -Message "Python probe 失败时必须人工审查"

$timeoutProbe = ConvertFrom-PythonRuntimeProbe -Json $null -TimedOut
Assert-True -Condition (-not [bool]$timeoutProbe.succeeded) -Message "Python probe 超时必须失败"
Assert-True -Condition ($timeoutProbe.error -like "*timed out*") -Message "Python probe 超时必须保留错误事实"

$processScope = New-PathScopeRecord -Source process -RawValue "D:\Process" -DotNetValue "D:\Process" -ReadErrors @() -MetadataResolver $rootResolver
$userScope = New-PathScopeRecord -Source user -RawValue "D:\User" -DotNetValue "D:\User" -ReadErrors @() -MetadataResolver $rootResolver
$machineScope = New-PathScopeRecord -Source machine -RawValue "D:\Machine" -DotNetValue "D:\Machine" -ReadErrors @() -MetadataResolver $rootResolver
$document = New-InventoryV3Document -Facts @{
    generatedAt = "2026-07-10T00:00:00.0000000+08:00"
    host = [pscustomobject]@{ computerName = "fixture" }
    outputDir = "D:\Reports"
    projectRoots = @("D:\Projects")
    excludedRoots = @()
    versionProbeTimeoutSeconds = 12
    includeSizes = $false
    skipVersionProbe = $true
    tools = @($pythonDecision)
    selectedEnvironmentVariables = @()
    pathScopes = [pscustomobject]@{ process = $processScope; user = $userScope; machine = $machineScope }
    directories = @()
    projectEnvironmentMarkers = @()
    localEnvironmentFindings = @()
    migrationCandidates = @()
    manualReviewItems = @()
}
Assert-True -Condition ($document.artifactType -eq "env-governance.inventory") -Message "inventory artifactType 错误"
Assert-True -Condition ($document.schemaVersion -eq 3) -Message "inventory schemaVersion 必须为 3"
Assert-True -Condition (-not [bool]$document.executionAllowed) -Message "inventory 不得授权执行"
Assert-True -Condition ($document.pathEntries[0].PSObject.Properties.Name.Count -eq 4) -Message "兼容 pathEntries 只能投影四个旧字段"
Assert-True -Condition ($document.pathEntries[0].path -eq $processScope.entries[0].expandedPath) -Message "兼容 pathEntries.path 必须投影 process expandedPath"
Assert-True -Condition ($document.pathScopes.process.source -eq "process") -Message "process scope 不得与 user scope 串联"
Assert-True -Condition ($document.pathScopes.user.source -eq "user") -Message "user scope 不得与 machine scope 串联"
Assert-True -Condition ($document.pathScopes.machine.source -eq "machine") -Message "machine scope 不得与 user scope 串联"

[pscustomobject]@{
    ok = $true
}
