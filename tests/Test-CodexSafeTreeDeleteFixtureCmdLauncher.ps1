[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$entryPath = Join-Path $PSScriptRoot 'Invoke-CodexSafeTreeDeleteFixture.ps1'
. (Join-Path $PSScriptRoot 'New-CodexSafeTreeDeleteTestScratchRoot.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1')
. (Join-Path $projectRoot 'scripts\lib\CodexSafeTreeDelete.ps1')

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-CaptureText {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.File]::Exists($Path)) { return '' }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0) { return '' }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [Text.UTF8Encoding]::new($false).GetString($bytes, 3, $bytes.Length - 3)
    }
    $oemCodePage = [int][Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage
    return [Text.Encoding]::GetEncoding($oemCodePage).GetString($bytes)
}

function Remove-TestTree {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.Directory]::Exists($Path)) { return }
    $snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $Path `
        -CapabilityRoot (Split-Path -Parent $Path) `
        -AllowedExactPaths @($Path) `
        -Name 'fixture .cmd launcher test cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot (Split-Path -Parent $Path) `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'fixture .cmd launcher test cleanup'
}

$scratchRoot = New-CodexSafeTreeDeleteTestScratchRoot -ProjectRoot $projectRoot -SuiteName 'fixturecmdlauncher'
# 即使 checkout 在纯 ASCII 路径，也让 launcher 目录强制含非 ASCII 字符。
$launcherRoot = Join-Path $scratchRoot '启动器中文目录'
$evidenceRoot = Join-Path $launcherRoot 'evidence'
$policyPath = Join-Path $launcherRoot 'policy.json'
$shimPath = Join-Path $launcherRoot 'invoke-safe-tree-delete.ps1'
$cmdPath = Join-Path $launcherRoot 'invoke-safe-tree-delete.cmd'
$utf8 = [Text.UTF8Encoding]::new($false)
$pwshExe = (Get-Process -Id $PID).Path

try {
    [void][IO.Directory]::CreateDirectory($evidenceRoot)
    $policy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 4
        entries = @([pscustomobject][ordered]@{
            id = 'fixture-cmd-launcher'
            capabilityRoot = $launcherRoot
            minimumDescendantDepth = 1
            rootDeletionPurpose = 'none'
            allowHardLinks = $false
            allowInternalDirectoryJunctions = $false
            deniedExactPaths = @($evidenceRoot)
        })
    }
    [IO.File]::WriteAllBytes($policyPath, $utf8.GetBytes(($policy | ConvertTo-Json -Depth 16)))

    $targetPath = Join-Path $launcherRoot '目标树'
    [void][IO.Directory]::CreateDirectory($targetPath)
    [IO.File]::WriteAllText((Join-Path $targetPath 'payload.txt'), 'fixture-cmd-launcher', $utf8)

    [IO.File]::WriteAllText($shimPath, (@'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
& '__SAFE_DELETE_ENTRY__' @args
exit $(if (Test-Path Variable:LASTEXITCODE) { $LASTEXITCODE } else { 0 })
'@).Replace('__SAFE_DELETE_ENTRY__', $entryPath), $utf8)
    # 与 ProductionSmoke 的 fixture .cmd 同一模式：%~dp0 相对引用同目录 shim，
    # 正文保持纯 ASCII（cmd.exe 按控制台代码页解析，非 ASCII 路径按 UTF-8 写入会以 123 拒绝）。
    [IO.File]::WriteAllText($cmdPath, (
        "@echo off`n" +
        ('"{0}" -NoLogo -NoProfile -NonInteractive -File "%~dp0invoke-safe-tree-delete.ps1" %*' -f $pwshExe) + "`n" +
        "exit /b %ERRORLEVEL%`n"), $utf8)

    $nonAsciiBytes = @([IO.File]::ReadAllBytes($cmdPath) | Where-Object { $_ -gt 127 })
    Assert-True ($nonAsciiBytes.Count -eq 0) '.cmd 正文必须纯 ASCII（含非 ASCII 路径时不得内嵌绝对路径）'

    $stdoutPath = Join-Path $launcherRoot 'plan.stdout.txt'
    $stderrPath = Join-Path $launcherRoot 'plan.stderr.txt'
    $process = Start-Process -FilePath $cmdPath `
        -ArgumentList @(
            '-Mode', 'Plan',
            '-TargetPath', $targetPath,
            '-CapabilityRoot', $launcherRoot,
            '-FixturePolicyPath', $policyPath,
            '-FixtureEvidenceRoot', $evidenceRoot,
            '-Json') `
        -WorkingDirectory $projectRoot `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -NoNewWindow -Wait -PassThru
    $stdout = Get-CaptureText -Path $stdoutPath
    $stderr = Get-CaptureText -Path $stderrPath
    Assert-True ($process.ExitCode -eq 0) (
        "fixture .cmd 经非 ASCII 路径执行必须成功（exit=$($process.ExitCode) stderr=$stderr）")
    $plan = $stdout | ConvertFrom-Json -Depth 16
    Assert-True ([bool]$plan.planned) '经 .cmd 的 Plan 必须返回 planned=true 的 JSON'
    Assert-True ([IO.File]::Exists([string]$plan.planPath)) '.cmd 调用的 plan.json 必须真实落盘'
    Assert-True ([string]$plan.planPath -like "$evidenceRoot*") 'plan.json 必须位于 fixture evidence 根内'

    [pscustomobject][ordered]@{
        ok = $true
        suite = 'CodexSafeTreeDeleteFixtureCmdLauncher'
        nonAsciiLauncherRoot = $true
        cmdPureAscii = $true
        planExitCode = $process.ExitCode
        planned = [bool]$plan.planned
    }
} finally {
    Remove-TestTree -Path $scratchRoot
}
