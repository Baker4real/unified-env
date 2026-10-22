Set-StrictMode -Version Latest

# #89：gate shim 生产安装字节的唯一生成逻辑。部署工具（Deploy-CodexSafeTreeDelete.ps1
# 的 Get-GateShimContent）与漂移检查（tests\Test-CodexSafeTreeDeleteShimDrift.ps1、
# Test-CodexSafeTreeDeleteProductionSmoke.ps1 的身份断言）共用这一份；部署工具的测试
# seam 常量重写不属于本 lib。生产安装除此处定义的内联外不做其它改写。

function Get-CodexSafeTreeDeleteGateShimInstallContent {
    # 安装内容 = 仓库 gate shim，其中唯一一行 gate holder lib dot-source 替换为同一 project
    # root 下该 lib 的原文（#77：已安装 shim 自包含，取锁前不加载任何仓库代码；面包屑的写、
    # 读与 stale 判定仍只有 scripts\lib\CodexSafeTreeDeleteGateHolder.ps1 一份源码）。
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $utf8 = [Text.UTF8Encoding]::new($false)
    $shimSource = Join-Path $ProjectRoot 'scripts\invoke-codex-safe-tree-delete-gate-shim.ps1'
    $holderLibSource = Join-Path $ProjectRoot 'scripts\lib\CodexSafeTreeDeleteGateHolder.ps1'
    $content = [IO.File]::ReadAllText($shimSource, $utf8)
    $holderInclude = ". (Join-Path `$PSScriptRoot 'lib\CodexSafeTreeDeleteGateHolder.ps1')"
    $includeCount = [regex]::Matches($content, [regex]::Escape($holderInclude)).Count
    if ($includeCount -ne 1) {
        throw "gate shim 必须恰好含一行 gate holder lib dot-source（实际 $includeCount 处），拒绝安装。"
    }
    $content = $content.Replace($holderInclude, (
        "# >>> inlined: scripts/lib/CodexSafeTreeDeleteGateHolder.ps1`n" +
        [IO.File]::ReadAllText($holderLibSource, $utf8).TrimEnd() +
        "`n# <<< inlined: scripts/lib/CodexSafeTreeDeleteGateHolder.ps1"))
    return $content
}

function Get-CodexSafeTreeDeleteGateShimInstallBytes {
    param([Parameter(Mandatory)][string]$ProjectRoot)

    return [Text.UTF8Encoding]::new($false).GetBytes(
        (Get-CodexSafeTreeDeleteGateShimInstallContent -ProjectRoot $ProjectRoot))
}

function Get-CodexSafeTreeDeleteGateShimInstallSha256Hex {
    # 文件内私有 helper：本 lib 的 SHA-256 小写十六进制只在此处计算一份。
    param([Parameter(Mandatory)][byte[]]$Bytes)

    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-CodexSafeTreeDeleteGateShimDrift {
    # 只读漂移判定：live wrapper 字节 vs 从 ProjectRoot 按生产规则生成的安装字节。
    # 返回双方的 SHA-256、期望值来源（生成规则与实际使用的源文件 SHA）与明确的漂移信息；
    # 相等时 driftMessage 为 $null。
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$LiveShimPath
    )

    if (-not [IO.File]::Exists($LiveShimPath)) {
        throw "live PowerShell wrapper 不存在：$LiveShimPath"
    }
    $expectedSha256 = Get-CodexSafeTreeDeleteGateShimInstallSha256Hex -Bytes (
        Get-CodexSafeTreeDeleteGateShimInstallBytes -ProjectRoot $ProjectRoot)
    $liveSha256 = Get-CodexSafeTreeDeleteGateShimInstallSha256Hex -Bytes ([IO.File]::ReadAllBytes($LiveShimPath))
    $shimSource = Join-Path $ProjectRoot 'scripts\invoke-codex-safe-tree-delete-gate-shim.ps1'
    $holderLibSource = Join-Path $ProjectRoot 'scripts\lib\CodexSafeTreeDeleteGateHolder.ps1'
    $equal = ([string]$liveSha256 -ceq [string]$expectedSha256)
    $driftMessage = $null
    if (-not $equal) {
        $driftMessage = ('live PowerShell wrapper 与部署工具按生产规则生成的 gate shim 安装字节不一致' +
            ('（部署漂移：仓库领先或落后于宿主安装）：live={0} expected={1}' -f $liveSha256, $expectedSha256))
    }
    return [pscustomobject][ordered]@{
        liveShimPath = $LiveShimPath
        projectRoot = $ProjectRoot
        liveSha256 = $liveSha256
        expectedSha256 = $expectedSha256
        expectedSource = [pscustomobject][ordered]@{
            rule = '部署工具 Get-GateShimContent 生产规则：gate shim 源内联 GateHolder lib，此外不做改写'
            shimSourcePath = 'scripts/invoke-codex-safe-tree-delete-gate-shim.ps1'
            shimSourceSha256 = Get-CodexSafeTreeDeleteGateShimInstallSha256Hex -Bytes ([IO.File]::ReadAllBytes($shimSource))
            gateHolderLibPath = 'scripts/lib/CodexSafeTreeDeleteGateHolder.ps1'
            gateHolderLibSha256 = Get-CodexSafeTreeDeleteGateShimInstallSha256Hex -Bytes ([IO.File]::ReadAllBytes($holderLibSource))
        }
        equal = $equal
        driftMessage = $driftMessage
    }
}
