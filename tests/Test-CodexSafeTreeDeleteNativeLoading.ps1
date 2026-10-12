[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# #86：safe-tree-delete lib 编译的全部 C# 组件（Status fast scan、Plan walker 与其余 native
# 组件）只经 CodexHostSafetyNativeLoader.ps1 的内容寻址 generation 加载。任一 source 变化只发布
# 新 generation，不改写已发布文件，因此工作树与生产互不干扰；旧的固定路径 StatusScan DLL 与
# .sha256 sidecar 不再被加载或写入。native 类型是进程级的，所以每个场景都在独立 pwsh 子进程中
# 按入口顺序 dot-source lib（或只用 loader 的 fixture seam）并回报 JSON。

$projectRoot = Split-Path -Parent $PSScriptRoot
$libDirectory = Join-Path $projectRoot 'scripts\lib'
$hostSafetyLibraryPath = Join-Path $libDirectory 'CodexHostSafety.ps1'
$libraryPath = Join-Path $libDirectory 'CodexSafeTreeDelete.ps1'
$loaderPath = Join-Path $libDirectory 'CodexHostSafetyNativeLoader.ps1'
$legacyCacheDirectory = [IO.Path]::Combine('D:\', 'Codex', 'temp', 'unified-env-addtype')
$legacyStatusScanPaths = @(
    (Join-Path $legacyCacheDirectory 'CodexSafeTreeDeleteStatusScan.dll'),
    (Join-Path $legacyCacheDirectory 'CodexSafeTreeDeleteStatusScan.dll.sha256')
)
$pwshPath = [Environment]::ProcessPath
$statusScanTypeNames = @(
    'CodexSafeTreeDelete.StatusScanCoordinator',
    'CodexSafeTreeDelete.StatusTreeSnapshotScanner'
)
$planWalkerTypeName = 'CodexSafeTreeDelete.PlanTreeSnapshotBuilder'
$sharedNativeTypeName = 'CodexSafeTreeDelete.FileIdentityReader'

. $hostSafetyLibraryPath
. (Join-Path $PSScriptRoot 'New-CodexSafeTreeDeleteTestScratchRoot.ps1')

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Remove-TestTree {
    param([Parameter(Mandatory)][string]$Path)

    if (-not [IO.Directory]::Exists($Path)) { return }
    $snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $Path `
        -CapabilityRoot (Split-Path -Parent $Path) `
        -AllowedExactPaths @($Path) `
        -Name 'safe-delete native loading test cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot (Split-Path -Parent $Path) `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'safe-delete native loading test cleanup'
}

function Get-LegacyStatusScanCacheFingerprint {
    # 只读指纹；FileShare 放开读写删，绝不阻塞仍在加载旧缓存的进程。
    $rows = [Collections.Generic.List[string]]::new()
    foreach ($path in $legacyStatusScanPaths) {
        $info = [IO.FileInfo]::new($path)
        if (-not $info.Exists) {
            $rows.Add(('{0}|absent' -f $path))
            continue
        }
        $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try {
            $sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream))
        } finally {
            $stream.Dispose()
        }
        $rows.Add(('{0}|{1}|{2}|{3}' -f $path, $info.Length, $info.LastWriteTimeUtc.Ticks, $sha256))
    }
    return ($rows -join "`n")
}

function Get-GenerationFingerprint {
    param([Parameter(Mandatory)][string]$GenerationDirectory)

    $rows = [Collections.Generic.List[string]]::new()
    foreach ($name in @('CodexHostSafetyNative.dll', 'generation-manifest.json')) {
        $info = [IO.FileInfo]::new((Join-Path $GenerationDirectory $name))
        Assert-True $info.Exists "generation 缺少 $name：$GenerationDirectory"
        $rows.Add(('{0}|{1}|{2}|{3}' -f $name, $info.Length, $info.LastWriteTimeUtc.Ticks,
                [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($info.FullName)))))
    }
    return ($rows -join "`n")
}

function Get-GenerationTypeNames {
    # 只读 metadata，不把 fixture generation 加载进测试进程。
    param([Parameter(Mandatory)][string]$GenerationDirectory)

    $bytes = [IO.File]::ReadAllBytes((Join-Path $GenerationDirectory 'CodexHostSafetyNative.dll'))
    $peReader = [Reflection.PortableExecutable.PEReader]::new([IO.MemoryStream]::new($bytes))
    try {
        $metadata = [Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($peReader)
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($handle in $metadata.TypeDefinitions) {
            $definition = $metadata.GetTypeDefinition($handle)
            [void]$names.Add(('{0}.{1}' -f $metadata.GetString($definition.Namespace), $metadata.GetString($definition.Name)))
        }
        return , $names
    } finally {
        $peReader.Dispose()
    }
}

function Invoke-ProbeChild {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [AllowNull()][string]$PlanWalkerEnv
    )

    $saved = [Environment]::GetEnvironmentVariable('CODEX_SAFE_TREE_DELETE_PLAN_CSHARP_WALKER')
    try {
        if ([string]::IsNullOrEmpty($PlanWalkerEnv)) {
            [Environment]::SetEnvironmentVariable('CODEX_SAFE_TREE_DELETE_PLAN_CSHARP_WALKER', $null)
        } else {
            [Environment]::SetEnvironmentVariable('CODEX_SAFE_TREE_DELETE_PLAN_CSHARP_WALKER', $PlanWalkerEnv)
        }
        $output = @(& $pwshPath -NoProfile -NonInteractive -File $ScriptPath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        [Environment]::SetEnvironmentVariable('CODEX_SAFE_TREE_DELETE_PLAN_CSHARP_WALKER', $saved)
    }
    $lines = @($output | ForEach-Object { [string]$_ })
    Assert-True ($exitCode -eq 0) ("探针子进程失败（exit={0}）：{1}" -f $exitCode, ($lines -join "`n"))
    $jsonLines = @($lines | Where-Object { $_.StartsWith('{') })
    Assert-True ($jsonLines.Count -ge 1) ("探针子进程没有输出 JSON：{0}" -f ($lines -join "`n"))
    return ($jsonLines[-1] | ConvertFrom-Json -Depth 16)
}

$libLoadProbe = @'
param(
    [Parameter(Mandatory)][string]$HostSafetyLibraryPath,
    [Parameter(Mandatory)][string]$LibraryPath,
    [Parameter(Mandatory)][string]$TypeNames
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. $HostSafetyLibraryPath
. $LibraryPath
$registry = Get-CodexHostSafetyNativeLoaderRegistryState
$types = [ordered]@{}
foreach ($name in @($TypeNames -split ',')) {
    $type = $name -as [type]
    $types[$name] = [ordered]@{
        resolved = ($null -ne $type)
        fromRegistryAssembly = ($null -ne $type -and $null -ne $registry -and
            [object]::ReferenceEquals($type.Assembly, $registry.assembly))
    }
}
$legacyAssemblies = @([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object {
        -not $_.IsDynamic -and [string]::Equals(
            [IO.Path]::GetFileName([string]$_.Location),
            'CodexSafeTreeDeleteStatusScan.dll',
            [StringComparison]::OrdinalIgnoreCase)
    })
[pscustomobject][ordered]@{
    loadedVariant = $(if ($null -ne $registry) { [string]$registry.loadedVariant } else { '' })
    types = $types
    legacyStatusScanAssemblyCount = $legacyAssemblies.Count
} | ConvertTo-Json -Depth 6 -Compress -EscapeHandling EscapeNonAscii
'@

$fixtureCompileProbe = @'
param(
    [Parameter(Mandatory)][string]$LoaderPath,
    [Parameter(Mandatory)][string]$TestParent,
    [Parameter(Mandatory)][string]$Nonce,
    [Parameter(Mandatory)][ValidateSet('base', 'default')][string]$Variant
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. $LoaderPath
$capability = New-CodexHostSafetyNativeFixtureCapability -TestParent $TestParent -Nonce $Nonce
$generation = Invoke-CodexHostSafetyNativeFixtureCompile -Capability $capability -Variant $Variant
[pscustomobject][ordered]@{
    root = [string]$capability.Root
    generationDirectory = [string]$generation.GenerationDirectory
    compiledHere = [bool]$generation.CompiledHere
} | ConvertTo-Json -Compress -EscapeHandling EscapeNonAscii
'@

$scratchRoot = New-CodexSafeTreeDeleteTestScratchRoot -ProjectRoot $projectRoot -SuiteName 'nativeload'
try {
    [void][IO.Directory]::CreateDirectory($scratchRoot)
    $libLoadProbePath = Join-Path $scratchRoot 'probe-lib-load.ps1'
    $fixtureCompileProbePath = Join-Path $scratchRoot 'probe-fixture-compile.ps1'
    [IO.File]::WriteAllText($libLoadProbePath, $libLoadProbe, [Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllText($fixtureCompileProbePath, $fixtureCompileProbe, [Text.UTF8Encoding]::new($true))
    $legacyBefore = Get-LegacyStatusScanCacheFingerprint
    $probeTypeNames = @($statusScanTypeNames + @($planWalkerTypeName, $sharedNativeTypeName))
    $libLoadArguments = @(
        '-HostSafetyLibraryPath', $hostSafetyLibraryPath,
        '-LibraryPath', $libraryPath,
        '-TypeNames', ($probeTypeNames -join ',')
    )

    # 1. 默认（Plan C# walker 开启）：Status fast scan、Plan walker 与其余 native 类型出自
    #    loader registry 登记的同一个内容寻址 generation；不再加载固定路径 StatusScan DLL。
    $defaultLoad = Invoke-ProbeChild -ScriptPath $libLoadProbePath -Arguments $libLoadArguments -PlanWalkerEnv $null
    Assert-True ([string]$defaultLoad.loadedVariant -ceq 'default') (
        "默认加载必须登记 default variant，实际为 '$($defaultLoad.loadedVariant)'")
    foreach ($name in $probeTypeNames) {
        Assert-True ([bool]$defaultLoad.types.$name.fromRegistryAssembly) (
            "默认加载时 $name 必须来自 loader registry 的内容寻址 generation")
    }
    Assert-True ([int]$defaultLoad.legacyStatusScanAssemblyCount -eq 0) (
        '默认加载不得再从固定路径 CodexSafeTreeDeleteStatusScan.dll 加载 Status fast scan')

    # 2. Plan walker kill switch（env=0 → base variant）：不含 PlanSnapshot，Status fast scan
    #    仍从同一 base generation 可用。
    $baseLoad = Invoke-ProbeChild -ScriptPath $libLoadProbePath -Arguments $libLoadArguments -PlanWalkerEnv '0'
    Assert-True ([string]$baseLoad.loadedVariant -ceq 'base') (
        "env=0 加载必须登记 base variant，实际为 '$($baseLoad.loadedVariant)'")
    Assert-True (-not [bool]$baseLoad.types.$planWalkerTypeName.resolved) (
        'env=0 不得加载 PlanSnapshot（Plan C# walker kill switch 失效）')
    foreach ($name in @($statusScanTypeNames + @($sharedNativeTypeName))) {
        Assert-True ([bool]$baseLoad.types.$name.fromRegistryAssembly) (
            "env=0 加载时 $name 必须来自 loader registry 的 base generation")
    }
    Assert-True ([int]$baseLoad.legacyStatusScanAssemblyCount -eq 0) (
        'env=0 加载不得再从固定路径 CodexSafeTreeDeleteStatusScan.dll 加载 Status fast scan')

    # 3. 两棵树共用一个 native 根：另一棵树改了 StatusScan source，只会发布自己的新
    #    generation，本树已发布的 generation 字节与时间戳不变。
    $treeBLibDirectory = Join-Path $scratchRoot 'tree-b\scripts\lib'
    [void][IO.Directory]::CreateDirectory($treeBLibDirectory)
    foreach ($source in @(@([IO.Directory]::GetFiles($libDirectory, '*.cs')) + @($loaderPath))) {
        [IO.File]::Copy($source, (Join-Path $treeBLibDirectory ([IO.Path]::GetFileName($source))))
    }
    [IO.File]::AppendAllText(
        (Join-Path $treeBLibDirectory 'CodexSafeTreeDeleteStatusScan.cs'),
        "`n// #86 fixture: tree-b StatusScan source drift`n",
        [Text.UTF8Encoding]::new($false))
    $nonce = [guid]::NewGuid().ToString('N').Substring(0, 16)
    $treeAArguments = @('-LoaderPath', $loaderPath, '-TestParent', $scratchRoot, '-Nonce', $nonce)
    $treeBArguments = @('-LoaderPath', (Join-Path $treeBLibDirectory 'CodexHostSafetyNativeLoader.ps1'),
        '-TestParent', $scratchRoot, '-Nonce', $nonce)

    $treeADefault = Invoke-ProbeChild -ScriptPath $fixtureCompileProbePath -Arguments ($treeAArguments + @('-Variant', 'default')) -PlanWalkerEnv $null
    $treeADefaultFingerprint = Get-GenerationFingerprint -GenerationDirectory $treeADefault.generationDirectory
    $treeADefaultTypes = Get-GenerationTypeNames -GenerationDirectory $treeADefault.generationDirectory
    foreach ($name in $probeTypeNames) {
        Assert-True $treeADefaultTypes.Contains($name) "default generation 必须包含 $name"
    }

    $treeBDefault = Invoke-ProbeChild -ScriptPath $fixtureCompileProbePath -Arguments ($treeBArguments + @('-Variant', 'default')) -PlanWalkerEnv $null
    Assert-True ([string]$treeBDefault.root -ceq [string]$treeADefault.root) '两棵树必须共用同一个 fixture native 根'
    Assert-True ([string]$treeBDefault.generationDirectory -cne [string]$treeADefault.generationDirectory) (
        'StatusScan source 漂移必须落到新的内容寻址 generation，而不是复用或改写既有 generation')
    Assert-True ([bool]$treeBDefault.compiledHere) 'StatusScan source 漂移必须编译并发布自己的 generation'
    Assert-True ((Get-GenerationTypeNames -GenerationDirectory $treeBDefault.generationDirectory).Contains($statusScanTypeNames[0])) (
        '漂移树的 generation 必须包含 Status fast scan')
    Assert-True ((Get-GenerationFingerprint -GenerationDirectory $treeADefault.generationDirectory) -ceq $treeADefaultFingerprint) (
        '另一棵树发布 generation 后，本树已发布的 generation 字节与时间戳必须不变')

    # 4. 旧固定路径 StatusScan DLL 与 sidecar 前后不变（不存在时仍不存在）。
    Assert-True ((Get-LegacyStatusScanCacheFingerprint) -ceq $legacyBefore) (
        '加载 lib 不得写入、替换或删除旧的固定路径 StatusScan DLL 与 .sha256 sidecar')

    [pscustomobject][ordered]@{
        ok = $true
        suite = 'CodexSafeTreeDeleteNativeLoading'
        slices = 4
    }
} finally {
    Remove-TestTree -Path $scratchRoot
}
