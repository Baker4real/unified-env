[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $ProjectRoot 'scripts\lib\CodexHookPolicy.ps1')

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) { throw "断言失败：$Message" }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Message
    )

    try {
        & $Action
    } catch {
        return $_.Exception.Message
    }
    throw "未拒绝：$Message"
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace CodexHookGovernanceTests
{
    public sealed class RenameAttempt
    {
        public RenameAttempt(bool moved, int win32Error)
        {
            Moved = moved;
            Win32Error = win32Error;
        }

        public bool Moved { get; }
        public int Win32Error { get; }
    }

    public static class DirectoryRenameAttacker
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool MoveFileExW(string existingPath, string newPath, uint flags);

        public static RenameAttempt TryMove(string source, string destination)
        {
            bool moved = MoveFileExW(source, destination, 0);
            return new RenameAttempt(moved, moved ? 0 : Marshal.GetLastWin32Error());
        }
    }
}
'@

$fixtureRoot = Join-Path $ProjectRoot 'reports\codex-hook-deployment-test'
$testRoot = Join-Path $fixtureRoot 'directory-guard-test'
$externalRoot = Join-Path $fixtureRoot 'directory-guard-external'
foreach ($path in @($testRoot, $externalRoot)) {
    if ([IO.Directory]::Exists($path)) { Remove-Item -LiteralPath $path -Recurse -Force }
    [void][IO.Directory]::CreateDirectory($path)
}
$guardedParent = Join-Path $testRoot 'existing-parent'
[void][IO.Directory]::CreateDirectory($guardedParent)
$parkedParent = Join-Path $testRoot 'parked-parent'

$guard = Enter-CodexHookFixtureDirectoryChainGuard -DirectoryPath $guardedParent
try {
    $renameAttempt = [CodexHookGovernanceTests.DirectoryRenameAttacker]::TryMove($guardedParent, $parkedParent)
    if ($renameAttempt.Moved) {
        New-Item -ItemType Junction -Path $guardedParent -Target $externalRoot | Out-Null
    }
    [IO.File]::WriteAllText((Join-Path $guardedParent 'payload.txt'), 'guarded', [Text.UTF8Encoding]::new($false))

    Assert-True (-not $renameAttempt.Moved -and $renameAttempt.Win32Error -eq 32) 'guard 存活时另一路 rename 必须以 Win32 sharing violation 32 失败'
    Assert-True ([IO.Directory]::Exists($guardedParent) -and -not [IO.Directory]::Exists($parkedParent)) 'guarded parent identity 必须保持原路径'
    Assert-True (@(Get-ChildItem -LiteralPath $externalRoot -Force).Count -eq 0) 'rename+junction 攻击不得向外部 root 写入 payload'
} finally {
    $guard.Dispose()
}

$atomicParent = Join-Path $testRoot 'atomic-parent'
[void][IO.Directory]::CreateDirectory($atomicParent)
$atomicParkedParent = Join-Path $testRoot 'atomic-parent-parked'
$atomicTarget = Join-Path $atomicParent 'target.bin'
[byte[]]$atomicBefore = [Text.UTF8Encoding]::new($false).GetBytes('before')
[byte[]]$atomicAfter = [Text.UTF8Encoding]::new($false).GetBytes('after')
[IO.File]::WriteAllBytes($atomicTarget, $atomicBefore)
$script:atomicRenameAttempt = $null
Set-CodexHookAtomicFileBytes `
    -Path $atomicTarget `
    -Bytes $atomicAfter `
    -ExpectedExists $true `
    -ExpectedSha256 (Get-CodexHookBytesSha256 -Bytes $atomicBefore) `
    -AfterSha256 (Get-CodexHookBytesSha256 -Bytes $atomicAfter) `
    -Scope 'directory guard atomic integration' `
    -BeforeMove {
        param($TargetPath)
        $script:atomicRenameAttempt = [CodexHookGovernanceTests.DirectoryRenameAttacker]::TryMove($atomicParent, $atomicParkedParent)
        if ($script:atomicRenameAttempt.Moved) {
            New-Item -ItemType Junction -Path $atomicParent -Target $externalRoot | Out-Null
        }
    }
Assert-True ($null -ne $script:atomicRenameAttempt -and -not $script:atomicRenameAttempt.Moved -and $script:atomicRenameAttempt.Win32Error -eq 32) 'atomic writer 必须在 BeforeMove 攻击期间持有 parent chain guard'
Assert-True ((Get-CodexHookBytesSha256 -Bytes ([IO.File]::ReadAllBytes($atomicTarget))) -ceq (Get-CodexHookBytesSha256 -Bytes $atomicAfter)) 'guarded atomic writer 必须发布目标 bytes'
Assert-True (@(Get-ChildItem -LiteralPath $externalRoot -Force).Count -eq 0) 'atomic writer 的 rename+junction 攻击不得写入外部 root'

$createdNested = Join-Path $testRoot 'created\nested'
[void](New-CodexHookFixtureDirectory -Path $createdNested -Name 'guard-created nested directory' -RequireMissing)
Assert-True ([IO.Directory]::Exists($createdNested)) 'guard 必须逐段创建 trusted root 下的缺失目录'
[void](Assert-Throws -Message 'RequireMissing directory 不得接受预先存在的 target' -Action {
    New-CodexHookFixtureDirectory -Path $createdNested -Name 'already-existing guarded directory' -RequireMissing | Out-Null
})

$danglingTarget = Join-Path $externalRoot 'must-not-be-created'
$danglingLink = Join-Path $testRoot 'dangling-junction'
$junctionOutput = & $env:ComSpec /d /c "mklink /J `"$danglingLink`" `"$danglingTarget`"" 2>&1
if ($LASTEXITCODE -ne 0) { throw "无法创建 dangling junction fixture：$junctionOutput" }
[void](Assert-Throws -Message 'dangling junction 不得被目录创建跟随' -Action {
    New-CodexHookFixtureDirectory -Path (Join-Path $danglingLink 'child') -Name 'dangling junction child' -RequireMissing | Out-Null
})
Assert-True (-not [IO.Directory]::Exists($danglingTarget)) 'dangling junction 外部 target 必须保持不存在'

$notDirectoryPath = Join-Path $testRoot 'not-a-directory.bin'
[IO.File]::WriteAllBytes($notDirectoryPath, [byte[]](1, 2, 3))
$notDirectoryError = Assert-Throws -Message 'directory chain guard 的 leaf 必须是普通目录' -Action {
    $notDirectoryGuard = Enter-CodexHookFixtureDirectoryChainGuard -DirectoryPath $notDirectoryPath
    try { } finally { if ($null -ne $notDirectoryGuard) { $notDirectoryGuard.Dispose() } }
}
Assert-True ($notDirectoryError -match 'directory|目录') '非目录 leaf 必须返回脱敏类型错误'

$rawMutationPattern = [regex]'\[IO\.(?:Directory|File)\]::(?:CreateDirectory|Move|Delete|WriteAllBytes|WriteAllText|Replace)\s*\(|\[IO\.FileStream\]::new\s*\('
$engineScriptPaths = @(
    (Join-Path $ProjectRoot 'scripts\New-CodexHookDeploymentPlan.ps1'),
    (Join-Path $ProjectRoot 'scripts\Invoke-CodexHookDeployment.ps1'),
    (Join-Path $ProjectRoot 'scripts\Restore-CodexHookDeployment.ps1')
)
foreach ($engineScriptPath in $engineScriptPaths) {
    $engineScriptText = [IO.File]::ReadAllText($engineScriptPath)
    Assert-True ($rawMutationPattern.Matches($engineScriptText).Count -eq 0) "deployment entry 不得绕过统一 guarded writer：$([IO.Path]::GetFileName($engineScriptPath))"
}

$policyPath = Join-Path $ProjectRoot 'scripts\lib\CodexHookPolicy.ps1'
$policyText = [IO.File]::ReadAllText($policyPath)
$atomicWriterStart = $policyText.IndexOf('function Set-CodexHookAtomicFileBytes', [StringComparison]::Ordinal)
$guardedDeleteStart = $policyText.IndexOf('function Remove-CodexHookFixtureFile', [StringComparison]::Ordinal)
$evidenceWriterStart = $policyText.IndexOf('function Set-CodexHookEvidenceJson', [StringComparison]::Ordinal)
Assert-True ($atomicWriterStart -ge 0 -and $guardedDeleteStart -gt $atomicWriterStart -and $evidenceWriterStart -gt $guardedDeleteStart) 'guarded writer function boundaries 必须可识别'
foreach ($rawMutation in $rawMutationPattern.Matches($policyText)) {
    $insideAtomicWriter = $rawMutation.Index -ge $atomicWriterStart -and $rawMutation.Index -lt $guardedDeleteStart
    $insideGuardedDelete = $rawMutation.Index -ge $guardedDeleteStart -and $rawMutation.Index -lt $evidenceWriterStart
    Assert-True ($insideAtomicWriter -or $insideGuardedDelete) 'Policy raw filesystem mutation 只能存在于统一 guarded atomic/delete helper 内'
}

[pscustomobject]@{
    ok = $true
    suite = 'CodexHookDirectoryGuard'
}
