[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# #89：live PowerShell wrapper（D:\Codex\.codex\scripts\invoke-safe-tree-delete.ps1）与
# 部署工具按生产规则从当前仓库生成的 gate shim 安装字节之间的只读漂移检查。不需要安静
# 窗口，不写宿主状态、不取 deployment mutex。安装字节的生成逻辑只有一份，在
# scripts\lib\CodexSafeTreeDeleteGateShimInstall.ps1（部署工具的安装路径复用同一 lib）。
# 场景：
# A. live 段：live wrapper 存在时，生成字节的 SHA-256 必须等于 live wrapper；不等即部署
#    漂移（仓库领先或落后于宿主安装），以含双 SHA 的明确信息失败。宿主没有 live wrapper
#    的环境（CI runner）记名 skip（liveCheck=skipped-absent-environment）。
# B. fixture 段（全部在 .scratch 下）：fixture 项目根（gate shim 源 + GateHolder lib 的
#    副本）自生成的安装字节写到 fixture「live」位置时检查相等；把 fixture 的 shim 源改得
#    与安装字节不一致、或改动安装副本时，必须检出漂移且信息含 live/expected 双 SHA 与
#    「部署漂移」；shim 源里 GateHolder lib dot-source 行数不等于 1、或被检 live 路径
#    缺失时失败闭锁。
$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'New-CodexSafeTreeDeleteTestScratchRoot.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDeleteGateShimInstall.ps1')
$utf8 = [Text.UTF8Encoding]::new($false)
$scratchRoot = New-CodexSafeTreeDeleteTestScratchRoot -ProjectRoot $projectRoot -SuiteName 'shimdrift'
$livePowerShellWrapper = 'D:\Codex\.codex\scripts\invoke-safe-tree-delete.ps1'

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-LowerSha256Text {
    param([Parameter(Mandatory)][string]$Path)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [IO.File]::ReadAllBytes($Path))).ToLowerInvariant()
}

function New-FixtureProjectRoot {
    param([Parameter(Mandatory)][string]$Root)
    [void][IO.Directory]::CreateDirectory((Join-Path $Root 'scripts\lib'))
    foreach ($relative in @(
            'scripts\invoke-codex-safe-tree-delete-gate-shim.ps1',
            'scripts\lib\CodexSafeTreeDeleteGateHolder.ps1')) {
        [IO.File]::Copy((Join-Path $projectRoot $relative), (Join-Path $Root $relative))
    }
}

function Assert-DriftDetected {
    param(
        [Parameter(Mandatory)][object]$Drift,
        [Parameter(Mandatory)][string]$Scenario
    )
    Assert-True (-not [bool]$Drift.equal) "$Scenario：必须检出漂移"
    $message = [string]$Drift.driftMessage
    Assert-True ($message.Contains([string]$Drift.liveSha256)) "$Scenario：漂移信息必须含 live SHA：$message"
    Assert-True ($message.Contains([string]$Drift.expectedSha256)) "$Scenario：漂移信息必须含 expected SHA：$message"
    Assert-True ($message.Contains('部署漂移')) "$Scenario：漂移信息必须指明部署漂移：$message"
}

$liveCheck = $null
$liveDrift = $null
try {
    if ([IO.File]::Exists($livePowerShellWrapper)) {
        $liveDrift = Get-CodexSafeTreeDeleteGateShimDrift -ProjectRoot $projectRoot -LiveShimPath $livePowerShellWrapper
        Assert-True ([bool]$liveDrift.equal) ('live wrapper 漂移检查失败：' + [string]$liveDrift.driftMessage)
        $liveCheck = 'ok'
    } else {
        $liveCheck = 'skipped-absent-environment'
    }

    $fixtureProject = Join-Path $scratchRoot 'fixture-project'
    New-FixtureProjectRoot -Root $fixtureProject
    $installedDir = Join-Path $scratchRoot 'installed'
    [void][IO.Directory]::CreateDirectory($installedDir)
    $installedPath = Join-Path $installedDir 'invoke-safe-tree-delete.ps1'
    $installBytes = Get-CodexSafeTreeDeleteGateShimInstallBytes -ProjectRoot $fixtureProject
    Assert-True ($installBytes.Count -gt 0) '生成字节必须非空'
    [IO.File]::WriteAllBytes($installedPath, $installBytes)

    $baseline = Get-CodexSafeTreeDeleteGateShimDrift -ProjectRoot $fixtureProject -LiveShimPath $installedPath
    Assert-True ([bool]$baseline.equal) ('fixture 自生成安装字节必须自洽：' + [string]$baseline.driftMessage)
    Assert-True ($null -eq $baseline.driftMessage) '相等时不得携带漂移信息'
    Assert-True ([string]$baseline.expectedSource.shimSourceSha256 -ceq (Get-LowerSha256Text -Path (Join-Path $fixtureProject 'scripts\invoke-codex-safe-tree-delete-gate-shim.ps1'))) `
        '期望值来源必须记录实际使用的 shim 源 SHA'
    Assert-True ([string]$baseline.expectedSource.gateHolderLibSha256 -ceq (Get-LowerSha256Text -Path (Join-Path $fixtureProject 'scripts\lib\CodexSafeTreeDeleteGateHolder.ps1'))) `
        '期望值来源必须记录实际使用的 GateHolder lib SHA'

    # 换一份改过的 shim 源（GateHolder lib 副本加一行）：必须检出漂移。
    $fixtureHolderLib = Join-Path $fixtureProject 'scripts\lib\CodexSafeTreeDeleteGateHolder.ps1'
    $originalHolderBytes = [IO.File]::ReadAllBytes($fixtureHolderLib)
    [IO.File]::AppendAllText($fixtureHolderLib, "# drift probe`n", $utf8)
    $sourceDrift = Get-CodexSafeTreeDeleteGateShimDrift -ProjectRoot $fixtureProject -LiveShimPath $installedPath
    Assert-DriftDetected -Drift $sourceDrift -Scenario '改动 fixture shim 源'
    Assert-True ([string]$sourceDrift.liveSha256 -ceq [string]$baseline.expectedSha256) '安装副本未变时 live SHA 必须不变'
    Assert-True ([string]$sourceDrift.expectedSha256 -cne [string]$baseline.expectedSha256) '源改动后期望 SHA 必须变化'
    [IO.File]::WriteAllBytes($fixtureHolderLib, $originalHolderBytes)

    # 源已还原，改安装副本（宿主落后/被改方向）：同样必须检出漂移。
    [IO.File]::AppendAllText($installedPath, "# host drift probe`n", $utf8)
    $installedDrift = Get-CodexSafeTreeDeleteGateShimDrift -ProjectRoot $fixtureProject -LiveShimPath $installedPath
    Assert-DriftDetected -Drift $installedDrift -Scenario '改动安装副本'
    Assert-True ([string]$installedDrift.expectedSha256 -ceq [string]$baseline.expectedSha256) '源还原后期望 SHA 必须回到基线'
    [IO.File]::WriteAllBytes($installedPath, $installBytes)

    # shim 源的 GateHolder lib dot-source 行数不等于 1：生成必须失败闭锁。
    $fixtureShim = Join-Path $fixtureProject 'scripts\invoke-codex-safe-tree-delete-gate-shim.ps1'
    $originalShimBytes = [IO.File]::ReadAllBytes($fixtureShim)
    $includeLine = ". (Join-Path `$PSScriptRoot 'lib\CodexSafeTreeDeleteGateHolder.ps1')"
    $brokenText = $utf8.GetString($originalShimBytes).Replace($includeLine, '# include removed')
    Assert-True ($brokenText -cne $utf8.GetString($originalShimBytes)) 'fixture shim 必须含 include 行才可移除'
    [IO.File]::WriteAllText($fixtureShim, $brokenText, $utf8)
    $includeGuardMessage = $null
    try {
        [void](Get-CodexSafeTreeDeleteGateShimInstallBytes -ProjectRoot $fixtureProject)
    } catch {
        $includeGuardMessage = [string]$_.Exception.Message
    }
    Assert-True ($null -ne $includeGuardMessage) 'include 行缺失时生成必须失败闭锁'
    Assert-True ($includeGuardMessage.Contains('恰好含一行')) "include 守护信息必须明确：$includeGuardMessage"
    [IO.File]::WriteAllBytes($fixtureShim, $originalShimBytes)

    # 被检 live 路径缺失：失败闭锁。
    $missingGuardMessage = $null
    try {
        [void](Get-CodexSafeTreeDeleteGateShimDrift -ProjectRoot $fixtureProject -LiveShimPath (Join-Path $scratchRoot 'missing-live.ps1'))
    } catch {
        $missingGuardMessage = [string]$_.Exception.Message
    }
    Assert-True ($null -ne $missingGuardMessage) 'live 路径缺失时必须失败闭锁'
} finally {
    if (Test-Path -LiteralPath $scratchRoot) {
        # 纯 fixture 字节，无 quarantine；直接清理。
        Remove-Item -LiteralPath $scratchRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

[pscustomobject][ordered]@{
    ok = $true
    suite = 'CodexSafeTreeDeleteShimDrift'
    liveCheck = $liveCheck
    liveShimPath = $livePowerShellWrapper
    liveSha256 = $(if ($null -ne $liveDrift) { [string]$liveDrift.liveSha256 } else { $null })
    expectedSha256 = $(if ($null -ne $liveDrift) { [string]$liveDrift.expectedSha256 } else { $null })
    expectedSource = $(if ($null -ne $liveDrift) { $liveDrift.expectedSource } else { $null })
    fixtureDriftScenarios = @('shim-source-mutated', 'installed-copy-mutated', 'include-count-guard', 'missing-live-guard')
}
