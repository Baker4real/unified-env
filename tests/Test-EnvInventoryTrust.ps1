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

$canonicalSharedRoots = @(Get-InventoryCanonicalSharedRoots)
Assert-True (($canonicalSharedRoots -join "|") -ceq "D:\Codex\tools|D:\Codex\envs|D:\hermes-data\.local|D:\hermes-data\.npm-global") "canonical shared roots 必须保持单一可信定义"
}

$unsafePathResolverCalls = 0
$unsafePathResolver = {
    param([string]$Path)
    $script:unsafePathResolverCalls++
    throw "resolver must not be called"
}
$unsafePathRejected = $false
try {
    New-PathScopeRecord -Source process -RawValue '\SystemRoot\System32' -DotNetValue '\SystemRoot\System32' -ReadErrors @() -MetadataResolver $unsafePathResolver | Out-Null
} catch {
    $unsafePathRejected = $true
}
Assert-True -Condition $unsafePathRejected -Message "PATH root-relative entry 必须在 metadata/filesystem resolver 前失败"
Assert-True -Condition ($unsafePathResolverCalls -eq 0) -Message "unsafe PATH 不得调用 metadata/filesystem resolver"

$unsafeToolResolverCalls = 0
$unsafeToolResolver = {
    param([string]$Path)
    $script:unsafeToolResolverCalls++
    throw "tool resolver must not be called"
}
$unsafeToolRejected = $false
try {
    Get-ToolOriginDecision -LauncherPath '\GLOBALROOT\Device\HarddiskVolume1\tool.exe' -RuntimePath $null -ProjectRoots @() -SharedRoots @('D:\Shared') -VendorRoots @() -SystemInstallerRoots @() -MetadataResolver $unsafeToolResolver | Out-Null
} catch {
    $unsafeToolRejected = $true
}
Assert-True -Condition $unsafeToolRejected -Message "tool launcher NT path 必须在 metadata/filesystem resolver 前失败"
Assert-True -Condition ($unsafeToolResolverCalls -eq 0) -Message "unsafe tool path 不得调用 metadata/filesystem resolver"

$uncResolver = {
    param([string]$Path)
    [pscustomobject]@{ status = "ok"; exists = $true; isReparsePoint = $false; reparseAncestor = $null; reparseTarget = $null }
}
$uncScope = New-PathScopeRecord -Source process -RawValue '\\server\share\tools' -DotNetValue '\\server\share\tools' -ReadErrors @() -MetadataResolver $uncResolver
Assert-True -Condition ([bool]$uncScope.complete -and $uncScope.entries[0].expandedPath -eq '\\server\share\tools') -Message "合法 UNC PATH 必须保留并通过"

$metadata = @{
    "C:\Windows\System32" = [pscustomobject]@{ status = "ok"; exists = $true; isReparsePoint = $false; reparseAncestor = $null; reparseTarget = $null }
    "D:\Tools" = [pscustomobject]@{ status = "ok"; exists = $true; isReparsePoint = $false; reparseAncestor = $null; reparseTarget = $null }
    "D:\Missing" = [pscustomobject]@{ status = "ok"; exists = $false; isReparsePoint = $false; reparseAncestor = $null; reparseTarget = $null }
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
    Assert-True -Condition ($scope.errors.Count -eq 0) -Message "完整 PATH scope 的 errors 必须为空"
    foreach ($entry in $scope.entries) {
        $actualFields = @($entry.PSObject.Properties.Name)
        $expectedFields = @("index", "rawPath", "expandedPath", "expansionStatus", "exists", "drive", "isReparsePoint", "reparseTarget")
        Assert-True -Condition (($actualFields -join ",") -ceq ($expectedFields -join ",")) -Message "PATH entry 字段必须固定"
    }

    $mismatch = New-PathScopeRecord -Source machine -RawValue "D:\Tools" -DotNetValue "D:\Missing" -ReadErrors @() -MetadataResolver $resolver
    Assert-True -Condition (-not [bool]$mismatch.complete) -Message "注册表/.NET PATH 不一致时 scope 必须不完整"
    Assert-True -Condition (@($mismatch.errors | Where-Object { $_ -like "*Registry/.NET*" }).Count -eq 1) -Message "Registry/.NET 不一致必须进入统一 errors"
    Assert-True -Condition ($mismatch.missingPathCleanupCandidates.Count -eq 0) -Message "不完整 scope 不得给出 missing cleanup 建议"

    $expansionFailure = New-PathScopeRecord -Source user -RawValue "%CODEX_TEST_UNDEFINED_ROOT%\bin" -DotNetValue "%CODEX_TEST_UNDEFINED_ROOT%\bin" -ReadErrors @() -MetadataResolver $resolver
    Assert-True -Condition (-not [bool]$expansionFailure.complete) -Message "PATH 展开失败时 scope 必须不完整"
    Assert-True -Condition ($expansionFailure.entries[0].expansionStatus -eq "failed") -Message "PATH 展开失败必须显式记录"
    Assert-True -Condition ($null -eq $expansionFailure.entries[0].drive) -Message "PATH 展开失败时 drive 必须为 null"
    Assert-True -Condition (@($expansionFailure.errors | Where-Object { $_ -like "*Expansion*" }).Count -eq 1) -Message "PATH 展开失败必须进入统一 errors"
    Assert-True -Condition ($expansionFailure.missingPathCleanupCandidates.Count -eq 0) -Message "展开失败时不得给出 missing cleanup 建议"

    $readFailure = New-PathScopeRecord -Source user -RawValue "D:\Missing" -DotNetValue "D:\Missing" -ReadErrors @("HKCU PATH read failed") -MetadataResolver $resolver
    Assert-True -Condition (-not [bool]$readFailure.complete) -Message "PATH 读取失败时 scope 必须不完整"
    Assert-True -Condition ($readFailure.readStatus -eq "error") -Message "PATH 读取失败必须显式标记 readStatus=error"
    Assert-True -Condition (@($readFailure.errors | Where-Object { $_ -like "*HKCU PATH read failed*" }).Count -eq 1) -Message "PATH 读取失败必须进入统一 errors"
    Assert-True -Condition ($readFailure.missingPathCleanupCandidates.Count -eq 0) -Message "读取失败时不得给出 missing cleanup 建议"

    $rootResolver = {
        param([string]$Path)
        [pscustomobject]@{ status = "ok"; exists = $true; isReparsePoint = $false; reparseAncestor = $null; reparseTarget = $null }
    }
    $driveRelativeRejected = $false
    try {
        New-PathScopeRecord -Source process -RawValue "C:\;C:" -DotNetValue "C:\;C:" -ReadErrors @() -MetadataResolver $rootResolver | Out-Null
    } catch {
        $driveRelativeRejected = $true
    }
    Assert-True -Condition $driveRelativeRejected -Message "驱动器相对 PATH C: 必须被正向 allowlist 拒绝"

    $hashScope = New-PathScopeRecord -Source process -RawValue "D:\abc" -DotNetValue "D:\abc" -ReadErrors @() -MetadataResolver $rootResolver
    Assert-True -Condition ($hashScope.rawValueSha256 -ceq "d7a3d07d779e5323c33c085a6eee317d9b0cd64026594d3632442be3a194da98") -Message "rawValueSha256 必须是 raw PATH 的真实 SHA-256"

    $metadataFailureResolver = {
        param([string]$Path)
        throw "fixture metadata failed"
    }
    $metadataFailure = New-PathScopeRecord -Source process -RawValue "D:\MetadataFailure" -DotNetValue "D:\MetadataFailure" -ReadErrors @() -MetadataResolver $metadataFailureResolver
    Assert-True -Condition (@($metadataFailure.errors | Where-Object { $_ -like "*Metadata*fixture metadata failed*" }).Count -eq 1) -Message "PATH metadata 失败必须进入统一 errors"

    $invalidPathMetadataResolvers = @(
        @{ name = "null"; resolver = { param([string]$Path) $null } }
        @{ name = "missing-fields"; resolver = { param([string]$Path) [pscustomobject]@{ status = "ok"; exists = $false } } }
        @{ name = "status-error"; resolver = { param([string]$Path) [pscustomobject]@{ status = "error"; error = "fixture status error" } } }
        @{ name = "throws"; resolver = { param([string]$Path) throw "fixture resolver throws" } }
    )
    foreach ($invalidCase in $invalidPathMetadataResolvers) {
        $invalidScope = New-PathScopeRecord -Source process -RawValue "D:\UntrustedMetadata" -DotNetValue "D:\UntrustedMetadata" -ReadErrors @() -MetadataResolver $invalidCase.resolver
        Assert-True -Condition (-not [bool]$invalidScope.complete) -Message "$($invalidCase.name) PATH metadata 必须使 scope 不完整"
        Assert-True -Condition ($invalidScope.missingPathCleanupCandidates.Count -eq 0) -Message "$($invalidCase.name) PATH metadata 不得生成 cleanup 建议"
        Assert-True -Condition (@($invalidScope.errors | Where-Object { $_ -like "Metadata*" }).Count -eq 1) -Message "$($invalidCase.name) PATH metadata 必须保留 error 摘要"
    }

    $junctionItemResolver = {
        param([string]$Path)
        switch ($Path) {
            "D:\Fixture\link\missing" { return [pscustomobject]@{ status = "missing"; path = $Path } }
            "D:\Fixture\link" { return [pscustomobject]@{ status = "ok"; path = $Path; isReparsePoint = $true; reparseTarget = "D:\Fixture\target" } }
            default { return [pscustomobject]@{ status = "ok"; path = $Path; isReparsePoint = $false; reparseTarget = $null } }
        }
    }
    $junctionChain = Get-InventoryReparseChainMetadata -Path "D:\Fixture\link\missing" -ItemMetadataResolver $junctionItemResolver
    Assert-True -Condition ($junctionChain.status -eq "ok") -Message "junction 父链 metadata 应成功"
    Assert-True -Condition (-not [bool]$junctionChain.exists) -Message "junction 下不存在叶子必须保留 exists=false"
    Assert-True -Condition ([bool]$junctionChain.isReparsePoint) -Message "junction 父链必须识别 reparse"
    Assert-True -Condition ($junctionChain.reparseAncestor -eq "D:\Fixture\link") -Message "junction 父链必须保留 ancestor"
    Assert-True -Condition ($junctionChain.reparseTarget -eq "D:\Fixture\target") -Message "junction 父链必须保留 target"
    $junctionScope = New-PathScopeRecord -Source process -RawValue "D:\Fixture\link\missing" -DotNetValue "D:\Fixture\link\missing" -ReadErrors @() -MetadataResolver { param([string]$Path) $junctionChain }.GetNewClosure()
    Assert-True -Condition (-not [bool]$junctionScope.complete) -Message "junction 父链证据必须使 scope fail-closed"
    Assert-True -Condition (-not ($junctionScope.entries[0].PSObject.Properties.Name -contains "reparseAncestor")) -Message "PATH entry schema 3 不得公开第 9 个 reparseAncestor 字段"
    Assert-True -Condition (@($junctionScope.errors | Where-Object { $_ -ceq "ReparseAncestor[0]: D:\Fixture\link" }).Count -eq 1) -Message "junction ancestor 必须通过 scope errors 保留稳定证据"
    Assert-True -Condition ($junctionScope.missingPathCleanupCandidates.Count -eq 0) -Message "junction 父链下的缺失 PATH 不得生成 cleanup 建议"

    $failingChainResolver = {
        param([string]$Path)
        if ($Path -eq "D:\Fixture\link\missing") {
            return [pscustomobject]@{ status = "missing"; path = $Path }
        }
        throw "fixture ancestor read failed"
    }
    $failedChain = Get-InventoryReparseChainMetadata -Path "D:\Fixture\link\missing" -ItemMetadataResolver $failingChainResolver
    Assert-True -Condition ($failedChain.status -eq "error") -Message "父链读取失败必须返回 status=error"
    $failedChainScope = New-PathScopeRecord -Source process -RawValue "D:\Fixture\link\missing" -DotNetValue "D:\Fixture\link\missing" -ReadErrors @() -MetadataResolver { param([string]$Path) $failedChain }.GetNewClosure()
    Assert-True -Condition (-not [bool]$failedChainScope.complete) -Message "父链读取失败必须使 scope 不完整"
    Assert-True -Condition ($failedChainScope.missingPathCleanupCandidates.Count -eq 0) -Message "父链读取失败不得生成 cleanup 建议"
} finally {
    $env:SystemRoot = $previousSystemRoot
}

$pythonProbeJson = '{"executable":"D:\\hermes-data\\hermes-agent\\venv-new\\Scripts\\python.exe","prefix":"D:\\hermes-data\\hermes-agent\\venv-new","basePrefix":"D:\\hermes-data\\.local\\python\\pythoncore-3.14-64"}'
$pythonRuntime = ConvertFrom-PythonRuntimeProbe -Json $pythonProbeJson
Assert-True -Condition ([bool]$pythonRuntime.succeeded) -Message "严格 Python JSON probe 应解析成功"

$originMetadata = {
    param([string]$Path)

    if ($Path -ieq "D:\Reparse\tool.exe") {
        return [pscustomobject]@{ status = "ok"; isReparsePoint = $true; reparseAncestor = $Path; reparseTarget = "D:\Vendor\tool.exe" }
    }
    return [pscustomobject]@{ status = "ok"; isReparsePoint = $false; reparseAncestor = $null; reparseTarget = $null }
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
    [pscustomobject]@{ status = "ok"; isReparsePoint = $true; reparseAncestor = $Path; reparseTarget = "D:\Shared\tool.exe" }
}
$projectReparse = Get-ToolOriginDecision -LauncherPath "D:\hermes-data\hermes-agent\venv-new\Scripts\python.exe" -RuntimePath $null -ProjectRoots @("D:\hermes-data\hermes-agent") -SharedRoots @("D:\Shared") -VendorRoots @() -SystemInstallerRoots @() -MetadataResolver $projectReparseMetadata
Assert-True -Condition ($projectReparse.originClass -eq "project-local-env") -Message "reparse 风险证据不得丢失项目 owner 事实"
Assert-True -Condition ([bool]$projectReparse.requiresManualReview) -Message "项目内 reparse 必须人工审查"

$launcherReparseRuntimeShared = Get-ToolOriginDecision -LauncherPath "D:\Reparse\tool.exe" -RuntimePath "D:\Shared\tool.exe" -RuntimeProbeSucceeded @decisionArgs
Assert-True -Condition ($launcherReparseRuntimeShared.originClass -eq "shared-tool") -Message "最终归属仍应反映 runtime owner"
Assert-True -Condition ([bool]$launcherReparseRuntimeShared.requiresManualReview) -Message "launcher/runtime 任一 reparse 都必须人工审查"

$riskyLauncherPaths = @(
    @{ path = "D:\Vendor\launcher.exe"; expected = "vendor-runtime" }
    @{ path = "C:\Program Files\Vendor\launcher.exe"; expected = "system-installer" }
    @{ path = "D:\hermes-data\hermes-agent\venv-new\Scripts\launcher.exe"; expected = "project-local-env" }
    @{ path = "D:\Unclassified\launcher.exe"; expected = "unknown" }
)
foreach ($riskCase in $riskyLauncherPaths) {
    $crossOwnerDecision = Get-ToolOriginDecision -LauncherPath $riskCase.path -RuntimePath "D:\Shared\runtime.exe" -RuntimeProbeSucceeded @decisionArgs
    Assert-True -Condition ($crossOwnerDecision.launcher.originClass -eq $riskCase.expected) -Message "launcher 风险归属错误: $($riskCase.path)"
    Assert-True -Condition ($crossOwnerDecision.originClass -eq "shared-tool") -Message "最终 origin 应保留 runtime owner"
    Assert-True -Condition ([bool]$crossOwnerDecision.requiresManualReview) -Message "$($riskCase.expected) launcher + shared runtime 仍必须人工审查"
}

foreach ($manualClassPath in @("D:\Vendor\tool.exe", "C:\Program Files\Vendor\tool.exe")) {
    $manualDecision = Get-ToolOriginDecision -LauncherPath $manualClassPath -RuntimePath $null @decisionArgs
    Assert-True -Condition ([bool]$manualDecision.requiresManualReview) -Message "$($manualDecision.originClass) 必须人工审查"
}

$taxonomyCases = @(
    @{ path = "C:\Windows\System32\cmd.exe"; expected = "windows-system" }
    @{ path = "C:\Program Files\WindowsApps\Vendor.App_1.0\app.exe"; expected = "windows-system" }
    @{ path = "C:\Users\Fixture\AppData\Local\Microsoft\WinGet\Packages\Vendor.Tool\tool.exe"; expected = "system-installer" }
    @{ path = "C:\Users\Fixture\bin\tool.exe"; expected = "user-profile" }
)
foreach ($taxonomyCase in $taxonomyCases) {
    $taxonomyDecision = Get-ToolOriginDecision -LauncherPath $taxonomyCase.path -RuntimePath "D:\Shared\runtime.exe" -LauncherProbeSucceeded -RuntimeProbeSucceeded -ProjectRoots @() -SharedRoots @("D:\Shared") -VendorRoots @() -WindowsSystemRoots @("C:\Windows", "C:\Program Files\WindowsApps") -SystemInstallerRoots @("C:\Program Files", "C:\Users\Fixture\AppData\Local\Microsoft\WinGet") -UserProfileRoots @("C:\Users\Fixture") -MetadataResolver $originMetadata
    Assert-True -Condition ($taxonomyDecision.launcher.originClass -eq $taxonomyCase.expected) -Message "taxonomy 分类错误: $($taxonomyCase.path) => $($taxonomyDecision.launcher.originClass)"
    Assert-True -Condition ($taxonomyDecision.originClass -eq "shared-tool") -Message "taxonomy 交叉组合应保留 runtime owner"
    Assert-True -Condition ([bool]$taxonomyDecision.requiresManualReview) -Message "$($taxonomyCase.expected) launcher + shared runtime 必须人工审查"
}

$failedSharedProbe = Get-ToolOriginDecision -LauncherPath "D:\Shared\tool.exe" -RuntimePath $null -ProjectRoots @() -SharedRoots @("D:\Shared") -VendorRoots @() -SystemInstallerRoots @() -MetadataResolver $originMetadata
Assert-True -Condition ($failedSharedProbe.originClass -eq "unknown") -Message "shared allowlist 没有成功 probe 时归属必须降级为 unknown"
Assert-True -Condition ([bool]$failedSharedProbe.requiresManualReview) -Message "shared allowlist probe 失败时必须人工审查"

$invalidToolMetadataResolvers = @(
    @{ name = "null"; resolver = { param([string]$Path) $null } }
    @{ name = "missing-fields"; resolver = { param([string]$Path) [pscustomobject]@{ status = "ok" } } }
    @{ name = "status-error"; resolver = { param([string]$Path) [pscustomobject]@{ status = "error"; error = "fixture status error" } } }
    @{ name = "throws"; resolver = { param([string]$Path) throw "fixture resolver throws" } }
)
foreach ($invalidCase in $invalidToolMetadataResolvers) {
    $invalidToolDecision = Get-ToolOriginDecision -LauncherPath "D:\Shared\tool.exe" -RuntimePath $null -LauncherProbeSucceeded -ProjectRoots @() -SharedRoots @("D:\Shared") -VendorRoots @() -SystemInstallerRoots @() -MetadataResolver $invalidCase.resolver
    Assert-True -Condition ($invalidToolDecision.originClass -eq "unknown") -Message "$($invalidCase.name) tool metadata 必须降级为 unknown"
    Assert-True -Condition ([bool]$invalidToolDecision.requiresManualReview) -Message "$($invalidCase.name) tool metadata 必须人工审查"
    Assert-True -Condition ($invalidToolDecision.launcher.matchedRule -eq "metadata-unavailable") -Message "$($invalidCase.name) tool metadata 必须保留不可信规则证据"
}

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
    projectRootFacts = @([pscustomobject]@{ path = "D:\Projects"; kind = "collection" })
    toolOwnerRoots = @("D:\Projects", "D:\hermes-data\hermes-agent")
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
Assert-True -Condition ($document.projectRootFacts[0].kind -eq "collection") -Message "inventory 必须保留 typed projectRootFacts"
Assert-True -Condition (-not [bool]$document.executionAllowed) -Message "inventory 不得授权执行"
Assert-True -Condition ($document.pathEntries[0].PSObject.Properties.Name.Count -eq 4) -Message "兼容 pathEntries 只能投影四个旧字段"
Assert-True -Condition ($document.pathEntries[0].path -eq $processScope.entries[0].expandedPath) -Message "兼容 pathEntries.path 必须投影 process expandedPath"
Assert-True -Condition ($document.pathScopes.process.source -eq "process") -Message "process scope 不得与 user scope 串联"
Assert-True -Condition ($document.pathScopes.user.source -eq "user") -Message "user scope 不得与 machine scope 串联"
Assert-True -Condition ($document.pathScopes.machine.source -eq "machine") -Message "machine scope 不得与 user scope 串联"

[pscustomobject]@{
    ok = $true
}
