Set-StrictMode -Version Latest

# #56 §4.3：safe-delete native assembly 的唯一 source 选择/digest/编译/发布/加载实现。
# CodexHostSafety.ps1 与 CodexSafeTreeDelete.ps1 只 dot-source 本文件并调用
# Invoke-CodexHostSafetyNativeLoad；禁止在别处复制第二套 cache 算法。
#
# 合同要点（docs/plans/2026-08-27-safe-tree-delete-issue56-implementation.md §4.3）：
# - source 集覆盖 safe-tree-delete lib 编译的全部 C# 组件（#86）：Status fast scan
#   （CodexSafeTreeDeleteStatusScan.cs）在两个 variant 都有，Plan walker 只在 default。新增组件
#   只加入本 source 集，不另建固定路径缓存。
# - env CODEX_SAFE_TREE_DELETE_PLAN_CSHARP_WALKER=0 必须在任何 PlanSnapshot source 的
#   读取/散列/编译之前判定：env=0 选 base source 集（不含 PlanSnapshot），默认选 base+PlanSnapshot。
# - cache 为不可变内容寻址 generation：<productionRoot>/<variant>/<compileCompositeSha>/，
#   composite 绑定 variant、有序 source SHA、loader contract version、PowerShell/.NET identity
#   与编译选项；任一变化产生新 generation。发布用 no-replace rename，不覆盖已认证 generation。
# - 源文件以 FileShare.Read（deny write/delete）句柄读取同一句柄字节，staging 完成前保持租约；
#   编译子进程只读 staging 副本。加载一律 Assembly.Load(byte[])（verify 后不按 path 重开）。
# - 进程 registry：{loadedVariant, compileCompositeSha, assemblySha256, assembly, requestedAlgorithm}。
#   转移：default→base 保持 default 类型、只切 requestedAlgorithm；首载 base 后请求 default
#   throw fresh-process-required；同 variant/composite 幂等。
# - fixture 编译 seam 只经显式进程内 capability 调用，生产加载路径永不触及。

$global:CodexHostSafetyNativeLoaderContractVersion = '2'

if ($null -eq (Get-Variable -Name CodexHostSafetyNativeLoaderRegistry -Scope Global -ErrorAction SilentlyContinue)) {
    $global:CodexHostSafetyNativeLoaderRegistry = $null
}

function Get-CodexHostSafetyNativeProductionRoot {
    return [IO.Path]::Combine('D:\', 'Codex', 'temp', 'unified-env-addtype')
}

function Get-CodexHostSafetyNativeSourceSet {
    param([Parameter(Mandatory)][ValidateSet('base', 'default')][string]$Variant)

    $libRoot = $PSScriptRoot
    $baseNames = @(
        'CodexHookHandleBoundIO.cs',
        'CodexSafeTreeDeleteFileIdentity.cs',
        'CodexSafeTreeDeleteHashCache.cs',
        'CodexSafeTreeDeleteApplySnapshot.cs',
        'CodexSafeTreeDeleteHostSafetyPurgeAdapter.cs',
        'CodexSafeTreeDeleteThreadJournal.cs',
        'CodexSafeTreeDeleteParallelPurge.cs',
        'CodexSafeTreeDeleteStatusScan.cs'
    )
    $sources = [Collections.Generic.List[string]]::new()
    foreach ($name in $baseNames) {
        $sources.Add((Join-Path $libRoot $name))
    }
    if ($Variant -ceq 'default') {
        $sources.Add((Join-Path $libRoot 'CodexSafeTreeDeletePlanSnapshot.cs'))
    }
    return [string[]]$sources.ToArray()
}

function Get-CodexHostSafetyNativeRequestedVariant {
    if ([string]$env:CODEX_SAFE_TREE_DELETE_PLAN_CSHARP_WALKER -ceq '0') {
        return 'base'
    }
    return 'default'
}

function Get-CodexHostSafetyNativeResolvedWalkerAlgorithm {
    # wrapper 行为判定（运行时权威顺序）：env=0 一律 PS；否则 PlanSnapshot 类型在
    # （loadedVariant=default 或兼容预载）→ csharp；base 已载（类型缺失）→ PS。
    # registry.requestedAlgorithm 只是 loader 上次请求的记账，不直接决定运行行为。
    if ([string]$env:CODEX_SAFE_TREE_DELETE_PLAN_CSHARP_WALKER -ceq '0') {
        return 'powershell-three-pass'
    }
    if ($null -ne ('CodexSafeTreeDelete.PlanTreeSnapshotBuilder' -as [type])) {
        return 'csharp-plan-snapshot'
    }
    return 'powershell-three-pass'
}

function Get-CodexHostSafetyNativeCompileIdentityParts {
    return @(
        ('contract={0}' -f $global:CodexHostSafetyNativeLoaderContractVersion),
        ('pwsh={0};edition={1}' -f [string]$PSVersionTable.PSVersion, [string]$PSVersionTable.PSEdition),
        ('clr={0}' -f [string][Environment]::Version),
        ('os={0}' -f [string][Environment]::OSVersion.VersionString),
        ('arch={0}' -f [string][System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture),
        'provider=Add-Type',
        'outputType=Library'
    )
}

function Get-CodexHostSafetyNativeFileSha256Hex {
    param([Parameter(Mandatory)][string]$Path)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [IO.File]::ReadAllBytes($Path))).ToLowerInvariant()
}

function Get-CodexHostSafetyNativeCompileCompositeSha256 {
    param(
        [Parameter(Mandatory)][string[]]$Sources,
        [Parameter(Mandatory)][ValidateSet('base', 'default')][string]$Variant
    )

    $parts = [Collections.Generic.List[string]]::new()
    foreach ($source in $Sources) {
        $parts.Add(('{0}={1}' -f [IO.Path]::GetFileName($source), (Get-CodexHostSafetyNativeFileSha256Hex -Path $source)))
    }
    $parts.Add(('variant={0}' -f $Variant))
    foreach ($identityPart in (Get-CodexHostSafetyNativeCompileIdentityParts)) {
        $parts.Add($identityPart)
    }
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.UTF8Encoding]::new($false).GetBytes(($parts -join "`n")))).ToLowerInvariant()
}

function Assert-CodexHostSafetyNativeNormalDirectory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Scope
    )

    $info = [IO.DirectoryInfo]::new($Path)
    if (-not $info.Exists) {
        throw "$Scope 目录不存在：$Path"
    }
    if (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Scope 目录是 reparse point，拒绝：$Path"
    }
}

function Assert-CodexHostSafetyNativeNormalFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Scope
    )

    $info = [IO.FileInfo]::new($Path)
    if (-not $info.Exists) {
        throw "$Scope 文件不存在：$Path"
    }
    if (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Scope 文件是 reparse point，拒绝：$Path"
    }
}

function Read-CodexHostSafetyNativeSourceBytesUnderLease {
    # FileShare.Read = 拒绝并发写/删除；staging 写出前保持全部句柄打开。
    param([Parameter(Mandatory)][string[]]$Sources)

    $reads = [Collections.Generic.List[object]]::new()
    foreach ($source in $Sources) {
        $stream = [IO.File]::Open($source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $bytes = [byte[]]::new([int]$stream.Length)
            [void]$stream.ReadExactly($bytes)
            $reads.Add([pscustomobject]@{ Path = $source; Stream = $stream; Bytes = $bytes })
        } catch {
            $stream.Dispose()
            throw
        }
    }
    return $reads
}

function Write-CodexHostSafetyNativeStagingCopy {
    param(
        [Parameter(Mandatory)][object]$Read,
        [Parameter(Mandatory)][string]$StagingDirectory
    )

    $stagingPath = Join-Path $StagingDirectory ([IO.Path]::GetFileName($Read.Path))
    [IO.File]::WriteAllBytes($stagingPath, [byte[]]$Read.Bytes)
    return $stagingPath
}

function Publish-CodexHostSafetyNativeGeneration {
    param(
        [Parameter(Mandatory)][string]$GenerationDirectory,
        [Parameter(Mandatory)][string]$DllPath,
        [Parameter(Mandatory)][string]$ManifestPath
    )

    [void][IO.Directory]::CreateDirectory($GenerationDirectory)
    $publishedDll = Join-Path $GenerationDirectory 'CodexHostSafetyNative.dll'
    $publishedManifest = Join-Path $GenerationDirectory 'generation-manifest.json'
    $dllTemp = Join-Path $GenerationDirectory 'CodexHostSafetyNative.dll.tmp'
    $manifestTemp = Join-Path $GenerationDirectory 'generation-manifest.json.tmp'
    [IO.File]::WriteAllBytes($dllTemp, [IO.File]::ReadAllBytes($DllPath))
    [IO.File]::WriteAllText($manifestTemp, [IO.File]::ReadAllText($ManifestPath, [Text.UTF8Encoding]::new($false)), [Text.UTF8Encoding]::new($false))
    try {
        [IO.File]::Move($dllTemp, $publishedDll)
        [IO.File]::Move($manifestTemp, $publishedManifest)
    } catch {
        foreach ($temp in @($dllTemp, $manifestTemp)) {
            if ([IO.File]::Exists($temp)) { [void][IO.File]::Delete($temp) }
        }
        if (-not ([IO.File]::Exists($publishedDll) -and [IO.File]::Exists($publishedManifest))) {
            throw
        }
    }
}

function Test-CodexHostSafetyNativeGenerationValid {
    param(
        [Parameter(Mandatory)][string]$GenerationDirectory,
        [Parameter(Mandatory)][string]$ExpectedCompositeSha256,
        [Parameter(Mandatory)][string]$ExpectedVariant
    )

    $manifestPath = Join-Path $GenerationDirectory 'generation-manifest.json'
    $dllPath = Join-Path $GenerationDirectory 'CodexHostSafetyNative.dll'
    if (-not ([IO.File]::Exists($manifestPath) -and [IO.File]::Exists($dllPath))) { return $false }
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json -Depth 16
    if ([string]$manifest.variant -cne $ExpectedVariant -or
        [string]$manifest.compileCompositeSha256 -cne $ExpectedCompositeSha256) {
        return $false
    }
    $actualDllSha = Get-CodexHostSafetyNativeFileSha256Hex -Path $dllPath
    return ([string]$manifest.dllSha256 -ceq $actualDllSha)
}

function Invoke-CodexHostSafetyNativeCompileGeneration {
    param(
        [Parameter(Mandatory)][string[]]$Sources,
        [Parameter(Mandatory)][ValidateSet('base', 'default')][string]$Variant,
        [Parameter(Mandatory)][string]$ProductionRoot
    )

    $compositeSha = Get-CodexHostSafetyNativeCompileCompositeSha256 -Sources $Sources -Variant $Variant
    $variantRoot = Join-Path $ProductionRoot $Variant
    $generationDirectory = Join-Path $variantRoot $compositeSha
    if (Test-CodexHostSafetyNativeGenerationValid `
            -GenerationDirectory $generationDirectory `
            -ExpectedCompositeSha256 $compositeSha `
            -ExpectedVariant $Variant) {
        return [pscustomobject]@{
            GenerationDirectory = $generationDirectory
            CompileCompositeSha256 = $compositeSha
            CompiledHere = $false
        }
    }

    $stagingDirectory = Join-Path $variantRoot ('staging-{0}' -f ([IO.Path]::GetRandomFileName()))
    [void][IO.Directory]::CreateDirectory($stagingDirectory)
    $reads = $null
    $stagedPaths = [Collections.Generic.List[string]]::new()
    try {
        # deny-write 租约读取 + staging 副本；编译只读 staging。
        $reads = Read-CodexHostSafetyNativeSourceBytesUnderLease -Sources $Sources
        foreach ($read in $reads) {
            $stagedPaths.Add((Write-CodexHostSafetyNativeStagingCopy -Read $read -StagingDirectory $stagingDirectory))
        }
        foreach ($read in $reads) { $read.Stream.Dispose() }
        $reads = $null

        $outputDll = Join-Path $stagingDirectory 'output.dll'
        Add-Type -Path ([string[]]$stagedPaths.ToArray()) `
            -OutputAssembly $outputDll `
            -OutputType Library `
            -ErrorAction Stop
        $manifest = [pscustomobject][ordered]@{
            schemaVersion = 1
            variant = $Variant
            compileCompositeSha256 = $compositeSha
            contractVersion = $global:CodexHostSafetyNativeLoaderContractVersion
            identity = [pscustomobject][ordered]@{}
            dllSha256 = (Get-CodexHostSafetyNativeFileSha256Hex -Path $outputDll)
            sources = @()
        }
        $identityTable = [ordered]@{}
        foreach ($identityPart in (Get-CodexHostSafetyNativeCompileIdentityParts)) {
            $key, $value = $identityPart -split '=', 2
            $identityTable[$key] = $value
        }
        $manifest.identity = $identityTable
        $sourceRows = [Collections.Generic.List[object]]::new()
        foreach ($source in $Sources) {
            $sourceRows.Add([pscustomobject][ordered]@{
                fileName = [IO.Path]::GetFileName($source)
                sha256 = (Get-CodexHostSafetyNativeFileSha256Hex -Path $source)
            })
        }
        $manifest.sources = @($sourceRows)
        $manifestPath = Join-Path $stagingDirectory 'generation-manifest.json'
        [IO.File]::WriteAllText(
            $manifestPath,
            ($manifest | ConvertTo-Json -Depth 8),
            [Text.UTF8Encoding]::new($false))

        # 全链 no-reparse 验证（root→variant→generation）后 no-replace 发布。
        Assert-CodexHostSafetyNativeNormalDirectory -Path $ProductionRoot -Scope 'native production root'
        Assert-CodexHostSafetyNativeNormalDirectory -Path $variantRoot -Scope 'native variant root'
        Publish-CodexHostSafetyNativeGeneration `
            -GenerationDirectory $generationDirectory `
            -DllPath $outputDll `
            -ManifestPath $manifestPath
        Assert-CodexHostSafetyNativeNormalDirectory -Path $generationDirectory -Scope 'native generation'
        Assert-CodexHostSafetyNativeNormalFile -Path (Join-Path $generationDirectory 'CodexHostSafetyNative.dll') -Scope 'native generation dll'
        Assert-CodexHostSafetyNativeNormalFile -Path (Join-Path $generationDirectory 'generation-manifest.json') -Scope 'native generation manifest'
        if (-not (Test-CodexHostSafetyNativeGenerationValid `
                -GenerationDirectory $generationDirectory `
                -ExpectedCompositeSha256 $compositeSha `
                -ExpectedVariant $Variant)) {
            throw 'native generation 发布后校验失败（并发 winner 不匹配）。'
        }
        return [pscustomobject]@{
            GenerationDirectory = $generationDirectory
            CompileCompositeSha256 = $compositeSha
            CompiledHere = $true
        }
    } finally {
        if ($null -ne $reads) {
            foreach ($read in $reads) { $read.Stream.Dispose() }
        }
        if ([IO.Directory]::Exists($stagingDirectory)) {
            [void][IO.Directory]::Delete($stagingDirectory, $true)
        }
    }
}

function Invoke-CodexHostSafetyNativeLoad {
    param(
        [Parameter(Mandatory)][ValidateSet('base', 'default')][string]$RequestedVariant
    )

    $registry = $global:CodexHostSafetyNativeLoaderRegistry
    if ($null -ne $registry) {
        if ([string]$registry.loadedVariant -ceq $RequestedVariant) {
            if ([string]$registry.compileCompositeSha256 -cne
                (Get-CodexHostSafetyNativeCompileCompositeSha256 `
                    -Sources (Get-CodexHostSafetyNativeSourceSet -Variant $RequestedVariant) `
                    -Variant $RequestedVariant)) {
                throw 'native registry composite 与当前 source 集不一致（同进程内 source 漂移）。'
            }
            return $registry.assembly
        }
        if ([string]$registry.loadedVariant -ceq 'default' -and $RequestedVariant -ceq 'base') {
            # default 已加载：保持 default 类型与 loadedVariant，只切行为算法。
            $registry.requestedAlgorithm = 'powershell-three-pass'
            return $registry.assembly
        }
        if ([string]$registry.loadedVariant -ceq 'base' -and $RequestedVariant -ceq 'default') {
            throw 'fresh-process-required：本进程首载 base variant，不能在同一进程内升级到 default。'
        }
        throw "native registry 未知转移：$($registry.loadedVariant) -> $RequestedVariant"
    }

    if ('CodexHookGovernance.HandleBoundFileReader' -as [type]) {
        # 类型已被本进程其它路径预载（如旧缓存路径），registry 缺位；登记兼容 registry。
        $global:CodexHostSafetyNativeLoaderRegistry = [pscustomobject]@{
            loadedVariant = $null
            compileCompositeSha256 = $null
            assemblySha256 = $null
            assembly = $null
            requestedAlgorithm = (Get-CodexHostSafetyNativeResolvedWalkerAlgorithm)
        }
        return $null
    }

    $productionRoot = Get-CodexHostSafetyNativeProductionRoot
    $sources = Get-CodexHostSafetyNativeSourceSet -Variant $RequestedVariant
    $generation = Invoke-CodexHostSafetyNativeCompileGeneration `
        -Sources $sources `
        -Variant $RequestedVariant `
        -ProductionRoot $productionRoot
    $dllPath = Join-Path $generation.GenerationDirectory 'CodexHostSafetyNative.dll'
    $manifestPath = Join-Path $generation.GenerationDirectory 'generation-manifest.json'
    if (-not (Test-CodexHostSafetyNativeGenerationValid `
            -GenerationDirectory $generation.GenerationDirectory `
            -ExpectedCompositeSha256 $generation.CompileCompositeSha256 `
            -ExpectedVariant $RequestedVariant)) {
        throw 'native generation 校验失败，拒绝加载。'
    }
    # verify 后不按 path 重开：字节一次读入，SHA 复验后 Assembly.Load(byte[])。
    $dllBytes = [IO.File]::ReadAllBytes($dllPath)
    $actualSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($dllBytes)).ToLowerInvariant()
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json -Depth 16
    if ([string]$manifest.dllSha256 -cne $actualSha) {
        throw 'native DLL 字节 SHA 与 manifest 不一致，拒绝加载。'
    }
    $assembly = [System.Reflection.Assembly]::Load($dllBytes)
    $global:CodexHostSafetyNativeLoaderRegistry = [pscustomobject]@{
        loadedVariant = $RequestedVariant
        compileCompositeSha256 = [string]$generation.CompileCompositeSha256
        assemblySha256 = $actualSha
        assembly = $assembly
        requestedAlgorithm = $(if ($RequestedVariant -ceq 'default') { 'csharp-plan-snapshot' } else { 'powershell-three-pass' })
    }
    return $assembly
}

function New-CodexHostSafetyNativeFixtureCapability {
    # 仅进程内对象引用；不可序列化、不能由环境继承。生产加载签名不接受该 capability。
    param(
        [Parameter(Mandatory)][string]$TestParent,
        [Parameter(Mandatory)][string]$Nonce
    )

    $fullParent = [IO.Path]::GetFullPath($TestParent)
    if (-not $fullParent.StartsWith('D:\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'fixture capability 只允许 D 盘 test parent。'
    }
    if ([string]::IsNullOrWhiteSpace($Nonce) -or $Nonce.Length -lt 16) {
        throw 'fixture capability nonce 必须至少 16 字符。'
    }
    $root = Join-Path $fullParent ('native-fixture-cache-{0}' -f $Nonce)
    [void][IO.Directory]::CreateDirectory($root)
    return [pscustomobject]@{ Kind = 'codex-native-fixture'; Nonce = $Nonce; Root = $root }
}

function Invoke-CodexHostSafetyNativeFixtureCompile {
    param(
        [Parameter(Mandatory)][object]$Capability,
        [Parameter(Mandatory)][ValidateSet('base', 'default')][string]$Variant
    )

    if ($null -eq $Capability -or
        [string]$Capability.Kind -cne 'codex-native-fixture' -or
        [string]::IsNullOrWhiteSpace([string]$Capability.Nonce) -or
        [string]::IsNullOrWhiteSpace([string]$Capability.Root)) {
        throw 'fixture compile 需要显式进程内 fixture capability。'
    }
    $sources = Get-CodexHostSafetyNativeSourceSet -Variant $Variant
    return Invoke-CodexHostSafetyNativeCompileGeneration `
        -Sources $sources `
        -Variant $Variant `
        -ProductionRoot ([string]$Capability.Root)
}

function Get-CodexHostSafetyNativeGenerationInventory {
    # fixture 测试用于证明生产 generation 字节集合前后不变。
    param([Parameter(Mandatory)][string]$ProductionRoot)

    if (-not [IO.Directory]::Exists($ProductionRoot)) { return @() }
    $rows = [Collections.Generic.List[object]]::new()
    $variants = [IO.Directory]::GetDirectories($ProductionRoot)
    foreach ($variantDir in $variants) {
        foreach ($generationDir in [IO.Directory]::GetDirectories($variantDir)) {
            $dllPath = Join-Path $generationDir 'CodexHostSafetyNative.dll'
            $manifestPath = Join-Path $generationDir 'generation-manifest.json'
            $rows.Add([pscustomobject][ordered]@{
                variant = [IO.Path]::GetFileName($variantDir)
                generation = [IO.Path]::GetFileName($generationDir)
                dllSha256 = $(if ([IO.File]::Exists($dllPath)) { Get-CodexHostSafetyNativeFileSha256Hex -Path $dllPath } else { $null })
                manifestSha256 = $(if ([IO.File]::Exists($manifestPath)) { Get-CodexHostSafetyNativeFileSha256Hex -Path $manifestPath } else { $null })
            })
        }
    }
    return @($rows)
}

function Get-CodexHostSafetyNativeLoaderRegistryState {
    return $global:CodexHostSafetyNativeLoaderRegistry
}
