[CmdletBinding()]
param(
    [ValidateSet("Check", "Repair", "Restore")]
    [string]$Mode = "Check",
    [string]$CodexHome = $env:CODEX_HOME,
    [string]$EvidencePath,
    [switch]$Json
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$script:HookPolicyPath = Join-Path $PSScriptRoot 'lib\CodexHookPolicy.ps1'
. $script:HookPolicyPath
$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$script:HostPreflightManifestPath = Join-Path $script:ProjectRoot 'managed\codex-hooks\host-preflight-manifest.json'
$script:HostPreflightManifest = Read-CodexHookHostPreflightManifest
$script:LifecycleEvidenceModulePath = Join-Path $script:ProjectRoot 'modules\codex-host\CodexHostHookEvidence.ps1'
if (-not (Test-Path -LiteralPath $script:LifecycleEvidenceModulePath -PathType Leaf)) {
    throw "codex-host evidence lifecycle module 缺失：$script:LifecycleEvidenceModulePath"
}
. $script:LifecycleEvidenceModulePath
$script:UserEnvironmentTransactionPath = Join-Path $PSScriptRoot 'lib\CodexUserEnvironmentTransaction.cs'
if (-not ('CodexHookGovernance.UserEnvironmentTransaction' -as [type])) {
    Add-Type -Path $script:UserEnvironmentTransactionPath
}
$script:CurrentEvidencePath = $null
$script:FixtureConcurrentReplacePath = $null
$script:FixtureConcurrentReplaceKind = "content"
$script:FixtureConcurrentReplaceRemaining = 0
$script:FixtureCasFailureMode = $null
$script:FixturePostCommitFailurePhase = $null
$script:FixtureForbiddenAclPath = $null
$script:FixtureManagedParentAttack = $null
$script:FixtureCreatedDirectoryCleanupReplace = $null
$script:FixtureLegacyDeleteReplace = $null
$script:FixtureLegacyDirectoryDeleteReplace = $null
$script:FixtureEvidenceAncestorReplace = $null
$script:FixtureAclCasReplace = $null
$script:FixtureRollbackAclCasReplace = $null
$script:FixtureRestoreInterruptAfter = $null
$script:FixtureRestoreFinalDrift = $null
$script:FixtureRestoreManifestCasReplace = $false
$script:FixtureRestoreBackupAfterSnapshot = $null
$script:FixtureRestoreAclReplace = $null
$script:FixtureRestoreContentParentReplace = $null
$script:FixtureRestoreManifestAclReplace = $null

$script:LegacyHookNames = @(
    "codex-mobile-permission-guard.cmd",
    "codex-mobile-permission-guard.py",
    "codex-projectless-root-d.cmd",
    "codex-projectless-root-d.js",
    "codex-provider-stability-guard.cmd",
    "codex-provider-stability-guard.ps1",
    "serena-activate-guarded.cmd",
    "serena-activate-guarded.ps1",
    "serena-dashboard-guard.cmd",
    "serena-dashboard-guard.ps1",
    "__pycache__\codex-mobile-permission-guard.cpython-313.pyc"
)
$script:LegacyHookDirectoryNames = @("__pycache__")
$script:TomlKeyPattern = '(?:[A-Za-z0-9_-]+|"(?:\\.|[^"\\])*"|''[^'']*'')'

function Get-Sha256 {
    param([string]$Path)

    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-TextSha256 {
    param([string]$Content)

    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Content)
    [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes))
}

function Test-IsLegacyHookRelativePath {
    param([string]$RelativePath)

    $normalized = $RelativePath.Replace('/', '\')
    if (@($script:LegacyHookNames | Where-Object { $_.Equals($normalized, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
        return $true
    }
    foreach ($directoryName in $script:LegacyHookDirectoryNames) {
        if ($normalized.Equals($directoryName, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    $false
}

function Test-IsManagedHookRelativePath {
    param([string]$RelativePath)

    $normalized = $RelativePath.Replace('/', '\')
    @($script:HostPreflightManifest.files | Where-Object {
        $managed = ([string]$_.liveRelativePath).Replace('/', '\')
        $managed.Equals($normalized, [System.StringComparison]::OrdinalIgnoreCase) -or
            $managed.StartsWith("$normalized\", [System.StringComparison]::OrdinalIgnoreCase)
    }).Count -gt 0
}

function Get-PreservedHookTreeInventory {
    param(
        [string]$HookDirectory,
        [object[]]$HookTree
    )

    @($HookTree | ForEach-Object {
        $relativePath = [System.IO.Path]::GetRelativePath($HookDirectory, $_.FullName).Replace('/', '\')
        if ((Test-IsLegacyHookRelativePath -RelativePath $relativePath) -or (Test-IsManagedHookRelativePath -RelativePath $relativePath)) {
            return
        }
        [pscustomobject]@{
            path = $relativePath
            kind = if ($_.PSIsContainer) { "directory" } else { "file" }
            sha256 = if ($_.PSIsContainer) { $null } else { Get-Sha256 -Path $_.FullName }
        }
    } | Sort-Object path)
}

function Get-RepairMutexName {
    param([string]$ResolvedCodexHome)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($ResolvedCodexHome.ToLowerInvariant())
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    $suffix = ([System.Convert]::ToHexString($hash)).Substring(0, 24)
    "Local\CodexHostHookReconciliation-$suffix"
}

function Assert-NoReparsePath {
    param(
        [string]$Path,
        [switch]$RequireLeaf
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if (-not $root.Equals("D:\", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "路径必须位于 D 盘：$fullPath"
    }

    $current = $root
    $relative = $fullPath.Substring($root.Length)
    foreach ($segment in @($relative -split '[\\/]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) {
            continue
        }

        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "路径不得穿过 reparse point：$current"
        }
        if (-not $item.PSIsContainer -and $item.LinkType -eq "HardLink") {
            throw "文件不得是 hard link：$current"
        }
    }

    if ($RequireLeaf -and -not (Test-Path -LiteralPath $fullPath)) {
        throw "路径不存在：$fullPath"
    }

    $fullPath
}

function Resolve-CodexHome {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        $Value = "D:\Codex\.codex"
    }
    if (-not [System.IO.Path]::IsPathFullyQualified($Value)) {
        throw "CodexHome 必须是绝对路径：$Value"
    }

    $fullPath = Assert-NoReparsePath -Path $Value -RequireLeaf
    if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
        throw "CodexHome 必须是目录：$fullPath"
    }

    foreach ($relative in @("config.toml", "hooks.json", "hooks")) {
        $requiredPath = Join-Path $fullPath $relative
        if (-not (Test-Path -LiteralPath $requiredPath)) {
            throw "CodexHome 缺少必要路径：$requiredPath"
        }
        Assert-NoReparsePath -Path $requiredPath -RequireLeaf | Out-Null
    }

    $fullPath.TrimEnd("\", "/")
}

function Assert-RepairHomeAuthorized {
    param([string]$ResolvedCodexHome)

    $liveHome = [System.IO.Path]::GetFullPath("D:\Codex\.codex").TrimEnd("\", "/")
    if ($ResolvedCodexHome.Equals($liveHome, [System.StringComparison]::OrdinalIgnoreCase)) {
        return
    }

    $projectRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd("\", "/")
    $fixtureRoot = Assert-NoReparsePath -Path (Join-Path $projectRoot ".scratch") -RequireLeaf
    $relative = [System.IO.Path]::GetRelativePath($fixtureRoot, $ResolvedCodexHome).Replace('/', '\')
    if ($relative -notmatch '^host-hook-reconciliation-tests-[0-9a-f]{32}\\[^\\]+\\\.codex\z') {
        throw "非默认 CodexHome 必须位于项目 .scratch 的专用 host-hook-reconciliation-tests 根内"
    }

    $markerPath = Join-Path $ResolvedCodexHome ".codex-host-hook-reconciliation-fixture"
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        throw "非默认 CodexHome 只允许带受控 fixture marker 的 Repair"
    }
    Assert-NoReparsePath -Path $markerPath -RequireLeaf | Out-Null
    if ((Read-Text -Path $markerPath).Trim() -cne "codex-host-hook-reconciliation-fixture-v1") {
        throw "fixture marker 内容不匹配，拒绝 Repair"
    }
}

function Initialize-FixtureTestSeams {
    param([string]$ResolvedCodexHome)

    $requestedPath = $env:CODEX_HOST_HOOK_TEST_CONCURRENT_REPLACE
    $postCommitFailurePhase = $env:CODEX_HOST_HOOK_TEST_POST_COMMIT_FAILURE
    $forbiddenAclPath = $env:CODEX_HOST_HOOK_TEST_FORBID_ACL_PATH
    $managedParentAttack = $env:CODEX_HOST_HOOK_TEST_MANAGED_PARENT_ATTACK
    $createdDirectoryCleanupReplace = $env:CODEX_HOST_HOOK_TEST_CREATED_DIRECTORY_CLEANUP_REPLACE
    $legacyDeleteReplace = $env:CODEX_HOST_HOOK_TEST_LEGACY_DELETE_REPLACE
    $legacyDirectoryDeleteReplace = $env:CODEX_HOST_HOOK_TEST_LEGACY_DIRECTORY_DELETE_REPLACE
    $evidenceAncestorReplace = $env:CODEX_HOST_HOOK_TEST_EVIDENCE_ANCESTOR_REPLACE
    $aclCasReplace = $env:CODEX_HOST_HOOK_TEST_ACL_CAS_REPLACE
    $rollbackAclCasReplace = $env:CODEX_HOST_HOOK_TEST_ROLLBACK_ACL_CAS_REPLACE
    if (
        [string]::IsNullOrWhiteSpace($requestedPath) -and
        [string]::IsNullOrWhiteSpace($postCommitFailurePhase) -and
        [string]::IsNullOrWhiteSpace($forbiddenAclPath) -and
        [string]::IsNullOrWhiteSpace($managedParentAttack) -and
        [string]::IsNullOrWhiteSpace($createdDirectoryCleanupReplace) -and
        [string]::IsNullOrWhiteSpace($legacyDeleteReplace) -and
        [string]::IsNullOrWhiteSpace($legacyDirectoryDeleteReplace) -and
        [string]::IsNullOrWhiteSpace($evidenceAncestorReplace) -and
        [string]::IsNullOrWhiteSpace($aclCasReplace) -and
        [string]::IsNullOrWhiteSpace($rollbackAclCasReplace)
    ) {
        return
    }

    $liveHome = [System.IO.Path]::GetFullPath("D:\Codex\.codex").TrimEnd("\", "/")
    if ($ResolvedCodexHome.Equals($liveHome, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "fixture-only test seam 不得用于 live CodexHome"
    }

    if (-not [string]::IsNullOrWhiteSpace($postCommitFailurePhase)) {
        if ($postCommitFailurePhase -notin @("managed", "environment", "registry", "acl", "legacy", "final")) {
            throw "fixture-only post-commit failure phase 无效"
        }
        $script:FixturePostCommitFailurePhase = $postCommitFailurePhase
    }

    if (-not [string]::IsNullOrWhiteSpace($forbiddenAclPath)) {
        $fullForbiddenAclPath = Assert-NoReparsePath -Path $forbiddenAclPath -RequireLeaf
        $hookRoot = [System.IO.Path]::GetFullPath((Join-Path $ResolvedCodexHome "hooks"))
        if (-not $fullForbiddenAclPath.StartsWith("$hookRoot\", [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "fixture-only forbidden ACL path 必须位于当前 hooks 内"
        }
        $relativeForbiddenAclPath = [System.IO.Path]::GetRelativePath($hookRoot, $fullForbiddenAclPath).Replace('/', '\')
        if (-not (Test-IsLegacyHookRelativePath -RelativePath $relativeForbiddenAclPath)) {
            throw "fixture-only forbidden ACL path 必须是待退役 allowlist 路径"
        }
        $script:FixtureForbiddenAclPath = $fullForbiddenAclPath
    }

    if (-not [string]::IsNullOrWhiteSpace($managedParentAttack)) {
        $attack = $managedParentAttack | ConvertFrom-Json
        if ((@($attack.PSObject.Properties.Name) -join ',') -cne 'targetParent,externalParent') {
            throw 'fixture-only managed parent attack schema 无效'
        }
        $targetParent = [IO.Path]::GetFullPath([string]$attack.targetParent).TrimEnd('\')
        $externalParent = [IO.Path]::GetFullPath([string]$attack.externalParent).TrimEnd('\')
        $expectedTargetParent = [IO.Path]::GetFullPath((Join-Path $ResolvedCodexHome 'hooks\lib')).TrimEnd('\')
        $fixtureRoot = [IO.Directory]::GetParent([IO.Directory]::GetParent($ResolvedCodexHome).FullName).FullName
        if (
            $targetParent -ine $expectedTargetParent -or
            -not $externalParent.StartsWith("$fixtureRoot\", [StringComparison]::OrdinalIgnoreCase) -or
            $externalParent.StartsWith("$ResolvedCodexHome\", [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $externalParent -PathType Container)
        ) {
            throw 'fixture-only managed parent attack capability 非法'
        }
        Assert-NoReparsePath -Path $targetParent -RequireLeaf | Out-Null
        Assert-NoReparsePath -Path $externalParent -RequireLeaf | Out-Null
        $script:FixtureManagedParentAttack = [pscustomobject]@{
            targetParent = $targetParent
            movedParent = "$targetParent.fixture-moved"
            externalParent = $externalParent
        }
        if (Test-Path -LiteralPath ([string]$script:FixtureManagedParentAttack.movedParent)) {
            throw 'fixture-only managed parent attack moved path 必须不存在'
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($createdDirectoryCleanupReplace)) {
        $replace = $createdDirectoryCleanupReplace | ConvertFrom-Json
        if ((@($replace.PSObject.Properties.Name) -join ',') -cne 'targetParent,externalParent') {
            throw 'fixture-only created directory cleanup replacement schema 无效'
        }
        $targetParent = [IO.Path]::GetFullPath([string]$replace.targetParent).TrimEnd('\')
        $externalParent = [IO.Path]::GetFullPath([string]$replace.externalParent).TrimEnd('\')
        $expectedTargetParent = [IO.Path]::GetFullPath((Join-Path $ResolvedCodexHome 'hooks\lib')).TrimEnd('\')
        $fixtureRoot = [IO.Directory]::GetParent([IO.Directory]::GetParent($ResolvedCodexHome).FullName).FullName
        if (
            $targetParent -ine $expectedTargetParent -or
            -not $externalParent.StartsWith("$fixtureRoot\", [StringComparison]::OrdinalIgnoreCase) -or
            $externalParent.StartsWith("$ResolvedCodexHome\", [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $externalParent -PathType Container)
        ) {
            throw 'fixture-only created directory cleanup replacement capability 非法'
        }
        Assert-NoReparsePath -Path $targetParent | Out-Null
        Assert-NoReparsePath -Path $externalParent -RequireLeaf | Out-Null
        $script:FixtureCreatedDirectoryCleanupReplace = [pscustomobject]@{
            targetParent = $targetParent
            movedParent = "$targetParent.fixture-cleanup-moved"
            externalParent = $externalParent
        }
        if (Test-Path -LiteralPath ([string]$script:FixtureCreatedDirectoryCleanupReplace.movedParent)) {
            throw 'fixture-only created directory cleanup replacement moved path 必须不存在'
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($legacyDeleteReplace)) {
        $replace = $legacyDeleteReplace | ConvertFrom-Json
        if ((@($replace.PSObject.Properties.Name) -join ',') -cne 'targetPath,replacementContent') {
            throw 'fixture-only legacy delete replacement schema 无效'
        }
        $targetPath = Assert-NoReparsePath -Path ([string]$replace.targetPath) -RequireLeaf
        $hookRoot = [IO.Path]::GetFullPath((Join-Path $ResolvedCodexHome 'hooks')).TrimEnd('\')
        $relativeTarget = [IO.Path]::GetRelativePath($hookRoot, $targetPath).Replace('/', '\')
        if (-not (Test-IsLegacyHookRelativePath -RelativePath $relativeTarget) -or [string]::IsNullOrEmpty([string]$replace.replacementContent)) {
            throw 'fixture-only legacy delete replacement capability 非法'
        }
        $script:FixtureLegacyDeleteReplace = [pscustomobject]@{
            targetPath = $targetPath
            replacementContent = [string]$replace.replacementContent
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($legacyDirectoryDeleteReplace)) {
        $replace = $legacyDirectoryDeleteReplace | ConvertFrom-Json
        if ((@($replace.PSObject.Properties.Name) -join ',') -cne 'targetPath,externalParent') { throw 'fixture-only legacy directory replacement schema 无效' }
        $targetPath = [IO.Path]::GetFullPath([string]$replace.targetPath).TrimEnd('\')
        $externalParent = [IO.Path]::GetFullPath([string]$replace.externalParent).TrimEnd('\')
        $hookRoot = [IO.Path]::GetFullPath((Join-Path $ResolvedCodexHome 'hooks')).TrimEnd('\')
        $relativeTarget = [IO.Path]::GetRelativePath($hookRoot, $targetPath).Replace('/', '\')
        $fixtureRoot = [IO.Directory]::GetParent([IO.Directory]::GetParent($ResolvedCodexHome).FullName).FullName
        if (-not (Test-IsLegacyHookRelativePath -RelativePath $relativeTarget) -or -not $externalParent.StartsWith("$fixtureRoot\", [StringComparison]::OrdinalIgnoreCase) -or $externalParent.StartsWith("$ResolvedCodexHome\", [StringComparison]::OrdinalIgnoreCase)) {
            throw 'fixture-only legacy directory replacement capability 非法'
        }
        Assert-NoReparsePath -Path $externalParent -RequireLeaf | Out-Null
        $script:FixtureLegacyDirectoryDeleteReplace = [pscustomobject]@{
            targetPath=$targetPath
            movedPath="$targetPath.fixture-moved"
            externalParent=$externalParent
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($evidenceAncestorReplace)) {
        $replace = $evidenceAncestorReplace | ConvertFrom-Json
        if ((@($replace.PSObject.Properties.Name) -join ',') -cne 'targetParent,externalParent') { throw 'fixture-only evidence ancestor replacement schema 无效' }
        $targetParent = [IO.Path]::GetFullPath([string]$replace.targetParent).TrimEnd('\')
        $externalParent = [IO.Path]::GetFullPath([string]$replace.externalParent).TrimEnd('\')
        $expectedRoot = (Resolve-CodexHostHookEvidenceScope -ResolvedCodexHome $ResolvedCodexHome).remediationRoot.TrimEnd('\')
        $fixtureRoot = [IO.Directory]::GetParent([IO.Directory]::GetParent($ResolvedCodexHome).FullName).FullName
        if ($targetParent -ine $expectedRoot -or -not $externalParent.StartsWith("$fixtureRoot\", [StringComparison]::OrdinalIgnoreCase) -or $externalParent.StartsWith("$ResolvedCodexHome\", [StringComparison]::OrdinalIgnoreCase)) { throw 'fixture-only evidence ancestor replacement capability 非法' }
        Assert-NoReparsePath -Path $externalParent -RequireLeaf | Out-Null
        $script:FixtureEvidenceAncestorReplace = [pscustomobject]@{ targetParent=$targetParent; movedParent="$targetParent.fixture-moved"; externalParent=$externalParent }
    }

    if (-not [string]::IsNullOrWhiteSpace($aclCasReplace)) {
        $aclPath = Assert-NoReparsePath -Path ([string]$aclCasReplace) -RequireLeaf
        if ($aclPath -ine [IO.Path]::GetFullPath((Join-Path $ResolvedCodexHome 'hooks.json'))) { throw 'fixture-only ACL CAS target 非法' }
        $script:FixtureAclCasReplace = $aclPath
    }
    if (-not [string]::IsNullOrWhiteSpace($rollbackAclCasReplace)) {
        $aclPath = Assert-NoReparsePath -Path ([string]$rollbackAclCasReplace) -RequireLeaf
        if ($aclPath -ine [IO.Path]::GetFullPath((Join-Path $ResolvedCodexHome 'hooks.json'))) { throw 'fixture-only rollback ACL CAS target 非法' }
        $script:FixtureRollbackAclCasReplace = $aclPath
    }

    if ([string]::IsNullOrWhiteSpace($requestedPath)) {
        return
    }

    $fullPath = Assert-NoReparsePath -Path $requestedPath -RequireLeaf
    $fixtureHostRoot = [System.IO.Directory]::GetParent($ResolvedCodexHome).FullName
    $fixtureSerenaContextPath = [System.IO.Path]::GetFullPath((Join-Path $fixtureHostRoot ".serena\contexts\codex-file-tools.yml"))
    if (
        -not $fullPath.StartsWith("$ResolvedCodexHome\", [System.StringComparison]::OrdinalIgnoreCase) -and
        -not $fullPath.Equals($fixtureSerenaContextPath, [System.StringComparison]::OrdinalIgnoreCase)
    ) {
        throw "fixture-only test seam 必须位于当前 CodexHome 内或精确目标 Serena context"
    }
    $script:FixtureConcurrentReplacePath = $fullPath
    $replaceKind = $env:CODEX_HOST_HOOK_TEST_CONCURRENT_KIND
    if (-not [string]::IsNullOrWhiteSpace($replaceKind)) {
        if ($replaceKind -notin @("content", "acl")) {
            throw "fixture-only concurrent replacement kind 无效"
        }
        $script:FixtureConcurrentReplaceKind = $replaceKind
    }
    $occurrenceText = $env:CODEX_HOST_HOOK_TEST_CONCURRENT_OCCURRENCE
    $occurrence = 1
    if (
        -not [string]::IsNullOrWhiteSpace($occurrenceText) -and
        (-not [int]::TryParse($occurrenceText, [ref]$occurrence) -or $occurrence -lt 1 -or $occurrence -gt 10)
    ) {
        throw "fixture-only concurrent replacement occurrence 无效"
    }
    $script:FixtureConcurrentReplaceRemaining = $occurrence
    $failureMode = $env:CODEX_HOST_HOOK_TEST_CAS_FAILURE_MODE
    if (-not [string]::IsNullOrWhiteSpace($failureMode)) {
        if ($failureMode -notin @("replace", "hash")) {
            throw "fixture-only CAS failure mode 无效"
        }
        $script:FixtureCasFailureMode = $failureMode
    }
}

function Get-ExceptionDataValue {
    param(
        [System.Exception]$Exception,
        [string]$Key
    )

    $cursor = $Exception
    while ($null -ne $cursor) {
        if ($cursor.Data.Contains($Key)) {
            return $cursor.Data[$Key]
        }
        $cursor = $cursor.InnerException
    }
    $null
}

function Get-ConcurrentReplaceRecord {
    param([System.Exception]$Exception)

    $path = [string](Get-ExceptionDataValue -Exception $Exception -Key "CodexConcurrentReplacePath")
    if ([string]::IsNullOrWhiteSpace($path)) {
        return $null
    }

    $backupPath = [string](Get-ExceptionDataValue -Exception $Exception -Key "CodexConcurrentBackupPath")
    [pscustomobject]@{
        path = $path
        backupRestored = [bool](Get-ExceptionDataValue -Exception $Exception -Key "CodexConcurrentBackupRestored")
        backupPath = if ([string]::IsNullOrWhiteSpace($backupPath)) { $null } else { $backupPath }
    }
}

function Read-Text {
    param([string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if (
        $bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and
        $bytes[2] -eq 0xBF
    ) {
        throw "受管文本文件不得包含 UTF-8 BOM：$Path"
    }
    try {
        [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    } catch [System.Text.DecoderFallbackException] {
        throw "受管文本文件不是严格 UTF-8：$Path"
    }
}

function ConvertTo-CodexComparableSddl {
    param([string]$Sddl)

    if ([string]::IsNullOrWhiteSpace($Sddl)) { return $Sddl }
    # Windows may materialize the DACL auto-inherited control bit (`AI`) after a
    # handle-bound ACL write even when the ACE list is unchanged. Treat only that
    # control-bit spelling difference as equivalent; owner, group, ACE order,
    # SIDs, rights, and the protected-DACL bit remain exact.
    [regex]::Replace($Sddl, 'D:([A-Z]*?)AI([A-Z]*)(?=\()', {
        param($match)
        "D:$($match.Groups[1].Value)$($match.Groups[2].Value)"
    })
}

function Test-CodexSddlEquivalent {
    param(
        [string]$Actual,
        [string]$Expected
    )

    if ($Actual -ceq $Expected) { return $true }
    (ConvertTo-CodexComparableSddl -Sddl $Actual) -ceq (ConvertTo-CodexComparableSddl -Sddl $Expected)
}

function Write-AtomicText {
    param(
        [string]$Path,
        [string]$Content,
        [string]$ExpectedCurrentSha256,
        [string]$ExpectedCurrentSddl
    )

    $directory = [System.IO.Path]::GetDirectoryName($Path)
    $fileName = [System.IO.Path]::GetFileName($Path)
    $tempPath = Join-Path $directory (".$fileName.tmp." + [guid]::NewGuid().ToString("N"))
    $replaceBackupPath = Join-Path $directory (".$fileName.replace-backup." + [guid]::NewGuid().ToString("N"))
    $preserveBackup = $false
    try {
        [System.IO.File]::WriteAllText($tempPath, $Content, [System.Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            if (
                $null -ne $script:FixtureConcurrentReplacePath -and
                $Path.Equals($script:FixtureConcurrentReplacePath, [System.StringComparison]::OrdinalIgnoreCase)
            ) {
                $script:FixtureConcurrentReplaceRemaining--
                if ($script:FixtureConcurrentReplaceRemaining -le 0) {
                    if ($script:FixtureConcurrentReplaceKind -eq "acl") {
                        Set-ProtectedAcl -Path $Path
                    } else {
                        [System.IO.File]::WriteAllText(
                            $Path,
                            "# fixture concurrent replacement`n",
                            [System.Text.UTF8Encoding]::new($false)
                        )
                    }
                    $script:FixtureConcurrentReplacePath = $null
                }
            }
            $preserveBackup = $true
            try {
                # File.Replace keeps the replacement file's ACL. A temp created
                # while elevated is owned by Administrators, which then fails
                # the published-ACL restore because the lease cannot change owner.
                $currentTargetAcl = Get-Acl -LiteralPath $Path
                $tempAcl = [System.Security.AccessControl.FileSecurity]::new()
                $tempAcl.SetSecurityDescriptorSddlForm([string]$currentTargetAcl.Sddl)
                Set-Acl -LiteralPath $tempPath -AclObject $tempAcl
                [System.IO.File]::Replace($tempPath, $Path, $replaceBackupPath, $false)
                if (
                    $script:FixtureCasFailureMode -eq "replace" -and
                    $null -eq $script:FixtureConcurrentReplacePath
                ) {
                    $script:FixtureCasFailureMode = $null
                    throw "fixture File.Replace partial failure"
                }
            } catch {
                if (Test-Path -LiteralPath $replaceBackupPath -PathType Leaf) {
                    $exception = [System.InvalidOperationException]::new("File.Replace 失败且已产生 backup", $_.Exception)
                    $exception.Data["CodexConcurrentReplacePath"] = $Path
                    $exception.Data["CodexConcurrentBackupPath"] = $replaceBackupPath
                    throw $exception
                }
                $preserveBackup = $false
                throw
            }
            if (-not [string]::IsNullOrWhiteSpace($ExpectedCurrentSha256)) {
                $backupHash = $null
                $backupSddl = $null
                $validationError = $null
                try {
                    if (
                        $script:FixtureCasFailureMode -eq "hash" -and
                        $null -eq $script:FixtureConcurrentReplacePath
                    ) {
                        $script:FixtureCasFailureMode = $null
                        throw "fixture CAS backup hash failure"
                    }
                    $backupHash = Get-Sha256 -Path $replaceBackupPath
                    $backupSddl = (Get-Acl -LiteralPath $replaceBackupPath).Sddl
                } catch {
                    $validationError = "无法验证原子替换 backup：$($_.Exception.Message)"
                }
                $metadataMismatch = (
                    -not [string]::IsNullOrWhiteSpace($ExpectedCurrentSddl) -and
                    -not (Test-CodexSddlEquivalent -Actual $backupSddl -Expected $ExpectedCurrentSddl)
                )
                if ($null -ne $validationError -or $backupHash -ne $ExpectedCurrentSha256 -or $metadataMismatch) {
                    $message = if ($null -ne $validationError) { $validationError } else { "目标文件在原子替换提交窗口发生内容或 ACL 并发变化" }
                    $exception = [System.InvalidOperationException]::new($message)
                    $exception.Data["CodexConcurrentReplacePath"] = $Path
                    $exception.Data["CodexConcurrentBackupPath"] = $replaceBackupPath
                    throw $exception
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($ExpectedCurrentSddl)) {
                $guard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire($directory, $directory, $false)
                $publishedLease = $null
                try {
                    Set-AclOwnerAndGroupFromSddl -Path $Path -Sddl $ExpectedCurrentSddl
                    $publishedLease = $guard.AcquireAclTargetLease($Path)
                    $publishedSddl = [string]$publishedLease.GetSecurityDescriptorSddl()
                    if (-not (Test-CodexSddlEquivalent -Actual $publishedSddl -Expected $ExpectedCurrentSddl)) {
                        $publishedLease.SetSecurityDescriptorSddl($publishedSddl, $ExpectedCurrentSddl)
                    }
                    if (-not (Test-CodexSddlEquivalent -Actual ([string]$publishedLease.GetSecurityDescriptorSddl()) -Expected $ExpectedCurrentSddl)) {
                        throw 'atomic text published ACL same-handle postcheck 失败'
                    }
                } finally {
                    if ($null -ne $publishedLease) { $publishedLease.Dispose() }
                    $guard.Dispose()
                }
            }
            $preserveBackup = $false
        } else {
            [System.IO.File]::Move($tempPath, $Path)
        }
    } finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force
        }
        if (-not $preserveBackup -and (Test-Path -LiteralPath $replaceBackupPath -PathType Leaf)) {
            Remove-Item -LiteralPath $replaceBackupPath -Force
        }
    }
}

function ConvertFrom-TomlDottedKeyName {
    param([string]$Name)

    $match = [regex]::Match(
        $Name,
        '^\s*(?<key>' + $script:TomlKeyPattern + ')\s*(?:\.\s*(?<key>' + $script:TomlKeyPattern + ')\s*)*$'
    )
    if (-not $match.Success) {
        throw "当前安全 parser 无法解析 TOML dotted key：$Name"
    }

    $segments = [System.Collections.Generic.List[string]]::new()
    foreach ($capture in $match.Groups['key'].Captures) {
        $token = $capture.Value
        if ($token.StartsWith('"', [System.StringComparison]::Ordinal)) {
            try {
                $decoded = ConvertFrom-Json -InputObject $token -NoEnumerate
            } catch {
                throw "当前安全 parser 无法解析 TOML quoted key：$token"
            }
            if ($decoded -isnot [string]) {
                throw "TOML quoted key 必须解析为字符串：$token"
            }
            $segments.Add($decoded)
        } elseif ($token.StartsWith("'", [System.StringComparison]::Ordinal)) {
            $segments.Add($token.Substring(1, $token.Length - 2))
        } else {
            $segments.Add($token)
        }
    }
    $segments.ToArray()
}

function Test-TomlKeySegmentsEqual {
    param(
        [string[]]$Left,
        [string[]]$Right
    )

    if ($Left.Count -ne $Right.Count) {
        return $false
    }
    for ($index = 0; $index -lt $Left.Count; $index++) {
        if ($Left[$index] -cne $Right[$index]) {
            return $false
        }
    }
    $true
}

function Get-TomlAssignmentKeySegments {
    param([string]$Line)

    $match = [regex]::Match(
        $Line,
        '^\s*(?<name>' + $script:TomlKeyPattern + '(?:\s*\.\s*' + $script:TomlKeyPattern + ')*)\s*='
    )
    if (-not $match.Success) {
        return
    }
    ConvertFrom-TomlDottedKeyName -Name $match.Groups['name'].Value
}

function Get-TomlAssignmentParts {
    param([string]$Line)

    $match = [regex]::Match(
        $Line,
        '^\s*(?<name>' + $script:TomlKeyPattern + '(?:\s*\.\s*' + $script:TomlKeyPattern + ')*)\s*=(?<value>.*)$'
    )
    if (-not $match.Success) {
        return $null
    }

    [pscustomobject]@{
        segments = @(ConvertFrom-TomlDottedKeyName -Name $match.Groups['name'].Value)
        value = [string]$match.Groups['value'].Value
    }
}

function Resolve-TomlParserPython {
    $runtimeRoot = Assert-NoReparsePath -Path "D:\Codex\tools\python314-official" -RequireLeaf
    foreach ($relativePath in @("Lib", "Lib\tomllib")) {
        $directoryPath = Assert-NoReparsePath -Path (Join-Path $runtimeRoot $relativePath) -RequireLeaf
        if (-not (Test-Path -LiteralPath $directoryPath -PathType Container)) {
            throw "TOML parser Python runtime 目录缺失"
        }
    }
    foreach ($relativePath in @(
        "python.exe",
        "python3.dll",
        "python314.dll",
        "Lib\tomllib\__init__.py",
        "Lib\tomllib\_parser.py",
        "Lib\tomllib\_re.py",
        "Lib\tomllib\_types.py"
    )) {
        $filePath = Assert-NoReparsePath -Path (Join-Path $runtimeRoot $relativePath) -RequireLeaf
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            throw "TOML parser Python runtime 文件缺失"
        }
    }

    $pythonPath = Join-Path $runtimeRoot "python.exe"
    $python = Get-Item -LiteralPath $pythonPath -Force
    if ($python.VersionInfo.ProductVersion -notmatch '^3\.14\.') {
        throw "TOML parser Python 版本不符合固定的 3.14 runtime 边界"
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $pythonPath
    if (
        $signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
        $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch '(^|,\s*)CN=Python Software Foundation(,|$)'
    ) {
        throw "TOML parser Python 未通过 Python Software Foundation 签名验证"
    }
    $pythonPath
}

function Wait-TomlParserTask {
    param(
        [System.Threading.Tasks.Task]$Task,
        [System.Diagnostics.Stopwatch]$Clock,
        [int]$TimeoutMilliseconds
    )

    while (-not $Task.IsCompleted) {
        $remaining = $TimeoutMilliseconds - [int]$Clock.ElapsedMilliseconds
        if ($remaining -le 0) {
            throw "TOML parser Python 超时"
        }
        Start-Sleep -Milliseconds ([Math]::Min(10, $remaining))
    }
    $Task.GetAwaiter().GetResult()
}

function Assert-ValidToml {
    param([string]$Content)

    $pythonPath = Resolve-TomlParserPython
    $pycacheRoot = Assert-NoReparsePath -Path (Resolve-CodexHostHookEvidenceScope -ForceProduction).runEvidenceRoot -RequireLeaf
    if (-not (Test-Path -LiteralPath $pycacheRoot -PathType Container)) {
        throw "TOML parser pycache 隔离根不存在"
    }
    $pycachePrefix = Assert-NoReparsePath -Path (Join-Path $pycacheRoot (".toml-parser-pycache-{0}" -f ([guid]::NewGuid().ToString("N"))))
    if (Test-Path -LiteralPath $pycachePrefix) {
        throw "TOML parser pycache 隔离路径必须不存在"
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $pythonPath
    foreach ($argument in @(
        "-B",
        "-I",
        "-S",
        "-X",
        "utf8",
        "-X",
        "pycache_prefix=$pycachePrefix",
        "-c",
        'import sys, tomllib; tomllib.loads(sys.stdin.read())'
    )) {
        $startInfo.ArgumentList.Add($argument)
    }
    $startInfo.WorkingDirectory = "D:\Codex"
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    $startInfo.StandardInputEncoding = $utf8
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.StandardErrorEncoding = $utf8

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $started = $false
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $timeoutMilliseconds = 5000
    try {
        $started = $process.Start()
        if (-not $started) {
            throw "TOML parser Python 未启动"
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $writeTask = $process.StandardInput.WriteAsync($Content)
        Wait-TomlParserTask -Task $writeTask -Clock $clock -TimeoutMilliseconds $timeoutMilliseconds | Out-Null
        $flushTask = $process.StandardInput.FlushAsync()
        Wait-TomlParserTask -Task $flushTask -Clock $clock -TimeoutMilliseconds $timeoutMilliseconds | Out-Null
        $process.StandardInput.Close()
        $remaining = $timeoutMilliseconds - [int]$clock.ElapsedMilliseconds
        if ($remaining -le 0 -or -not $process.WaitForExit($remaining)) {
            throw "TOML parser Python 超时"
        }
        Wait-TomlParserTask -Task $stdoutTask -Clock $clock -TimeoutMilliseconds $timeoutMilliseconds | Out-Null
        Wait-TomlParserTask -Task $stderrTask -Clock $clock -TimeoutMilliseconds $timeoutMilliseconds | Out-Null
        if ($process.ExitCode -ne 0) {
            throw "config.toml 未通过完整 TOML 语法验证"
        }
    } catch {
        switch -Exact ($_.Exception.Message) {
            "TOML parser Python 未启动" { throw "完整 TOML 语法验证失败：TOML parser Python 未启动" }
            "TOML parser Python 超时" { throw "完整 TOML 语法验证失败：TOML parser Python 超时" }
            "config.toml 未通过完整 TOML 语法验证" { throw "完整 TOML 语法验证失败：config.toml 未通过完整 TOML 语法验证" }
            default { throw "完整 TOML 语法验证失败：TOML parser I/O 失败" }
        }
    } finally {
        if ($started -and -not $process.HasExited) {
            try {
                $process.StandardInput.BaseStream.Dispose()
            } catch {
            }
            try {
                $process.Kill($true)
            } catch {
            }
            $process.WaitForExit(1000) | Out-Null
        }
        $process.Dispose()
    }
}

function Assert-NoHeaderLikeTomlContainerLine {
    param([string[]]$Lines)

    $arrayDepth = 0
    $inlineTableDepth = 0
    $tableHeaderPattern = '^\s*\[(?<name>[^\[\]]+)\]\s*(?:#.*)?$'
    $arrayTableHeaderPattern = '^\s*\[\[(?<name>[^\[\]]+)\]\]\s*(?:#.*)?$'
    foreach ($line in $Lines) {
        $looksLikeTableHeader = [regex]::IsMatch($line, $tableHeaderPattern)
        $looksLikeArrayTableHeader = [regex]::IsMatch($line, $arrayTableHeaderPattern)
        if (
            ($arrayDepth -gt 0 -or $inlineTableDepth -gt 0) -and
            ($looksLikeTableHeader -or $looksLikeArrayTableHeader)
        ) {
            throw 'TOML 多行容器包含 header-like 元素；当前定向 parser 无法安全区分，拒绝写入'
        }
        if ($arrayDepth -eq 0 -and $inlineTableDepth -eq 0 -and ($looksLikeTableHeader -or $looksLikeArrayTableHeader)) {
            continue
        }

        $quote = [char]0
        $escaped = $false
        for ($column = 0; $column -lt $line.Length; $column++) {
            $character = $line[$column]
            if ($quote -ne [char]0) {
                if ($quote -eq '"' -and $escaped) {
                    $escaped = $false
                    continue
                }
                if ($quote -eq '"' -and $character -eq '\') {
                    $escaped = $true
                    continue
                }
                if ($character -eq $quote) {
                    $quote = [char]0
                }
                continue
            }
            if ($character -eq '#') {
                break
            }
            if ($character -eq '"' -or $character -eq "'") {
                $quote = $character
                continue
            }
            if ($character -eq '[') {
                $arrayDepth++
                continue
            }
            if ($character -eq ']') {
                $arrayDepth--
                if ($arrayDepth -lt 0) {
                    throw 'TOML array container 边界非法'
                }
                continue
            }
            if ($character -eq '{') {
                $inlineTableDepth++
                continue
            }
            if ($character -eq '}') {
                $inlineTableDepth--
                if ($inlineTableDepth -lt 0) {
                    throw 'TOML inline table container 边界非法'
                }
            }
        }
        if ($quote -ne [char]0) {
            throw '当前安全 parser 不处理跨行或未终止 TOML string；拒绝写入'
        }
    }
    if ($arrayDepth -ne 0 -or $inlineTableDepth -ne 0) {
        throw 'TOML container 边界未闭合；拒绝写入'
    }
}

function Invoke-FixturePostCommitFailure {
    param([ValidateSet("managed", "environment", "registry", "acl", "legacy", "final")][string]$Phase)

    if ($script:FixturePostCommitFailurePhase -ceq $Phase) {
        $script:FixturePostCommitFailurePhase = $null
        throw "fixture-only post-commit $Phase failure"
    }
}

function Get-TomlDocument {
    param([string]$Content)

    Assert-ValidToml -Content $Content
    if ($Content.Contains("'''") -or $Content.Contains('"""')) {
        throw "当前安全 parser 不处理 TOML 多行字符串；为避免把正文误判为 section，拒绝写入"
    }

    $newLine = if ($Content.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [regex]::Split($Content, "\r?\n")
    Assert-NoHeaderLikeTomlContainerLine -Lines $lines
    $headers = [System.Collections.Generic.List[object]]::new()
    $tomlDottedKeyPattern = $script:TomlKeyPattern + '(?:\s*\.\s*' + $script:TomlKeyPattern + ')*'
    $tableHeaderPattern = '^\s*\[(?<name>' + $tomlDottedKeyPattern + ')\]\s*(?:#.*)?$'
    $arrayTableHeaderPattern = '^\s*\[\[(?<name>' + $tomlDottedKeyPattern + ')\]\]\s*(?:#.*)?$'
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $match = [regex]::Match($lines[$index], $tableHeaderPattern)
        if ($match.Success) {
            $segments = @(ConvertFrom-TomlDottedKeyName -Name $match.Groups['name'].Value)
            $headers.Add([pscustomobject]@{
                index = $index
                name = $match.Groups['name'].Value
                segments = $segments
                kind = "table"
            })
            continue
        }
        $arrayMatch = [regex]::Match($lines[$index], $arrayTableHeaderPattern)
        if ($arrayMatch.Success) {
            $segments = @(ConvertFrom-TomlDottedKeyName -Name $arrayMatch.Groups['name'].Value)
            $headers.Add([pscustomobject]@{
                index = $index
                name = $arrayMatch.Groups['name'].Value
                segments = $segments
                kind = "array-table"
            })
        }
    }

    [pscustomobject]@{
        lines = $lines
        newLine = $newLine
        headers = $headers.ToArray()
    }
}

function Get-UniqueSectionRange {
    param(
        [object]$Document,
        [string]$Name,
        [switch]$AllowMissing
    )

    $expectedSegments = @($Name.Split('.'))
    $matchingSectionHeaders = @($Document.headers | Where-Object {
        $_.kind -ceq "table" -and (Test-TomlKeySegmentsEqual -Left @($_.segments) -Right $expectedSegments)
    })
    if ($matchingSectionHeaders.Count -eq 0 -and $AllowMissing) {
        return $null
    }
    if ($matchingSectionHeaders.Count -ne 1) {
        throw "TOML section 必须恰好出现一次：[$Name]；实际 $($matchingSectionHeaders.Count)"
    }

    $header = $matchingSectionHeaders[0]
    $next = @($Document.headers | Where-Object { $_.index -gt $header.index } | Sort-Object index | Select-Object -First 1)
    [pscustomobject]@{
        start = $header.index + 1
        end = if ($next.Count -eq 1) { $next[0].index } else { $Document.lines.Count }
    }
}

function Get-UniqueKeyIndex {
    param(
        [object]$Document,
        [string]$Key,
        [int]$Start,
        [int]$End
    )

    $keyIndices = @(Get-TomlKeyIndices -Document $Document -Key $Key -Start $Start -End $End)
    if ($keyIndices.Count -ne 1) {
        throw "TOML key 必须在目标作用域恰好出现一次：$Key；实际 $($keyIndices.Count)"
    }

    $keyIndices[0]
}

function New-FixtureJunction {
    param(
        [string]$JunctionPath,
        [string]$TargetPath
    )

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'C:\Windows\System32\cmd.exe'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    [void]$start.ArgumentList.Add('/d')
    [void]$start.ArgumentList.Add('/c')
    [void]$start.ArgumentList.Add('mklink')
    [void]$start.ArgumentList.Add('/J')
    [void]$start.ArgumentList.Add($JunctionPath)
    [void]$start.ArgumentList.Add($TargetPath)
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'fixture-only junction 进程启动失败' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(5000)) {
            try { $process.Kill($true) } catch {}
            [void]$process.WaitForExit(1000)
            throw 'fixture-only junction 创建超时'
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "fixture-only junction 创建失败：exit=$($process.ExitCode); stdout=$($stdout.Trim()); stderr=$($stderr.Trim())"
        }
    } finally { $process.Dispose() }
}

function Remove-FixtureJunction {
    param([string]$JunctionPath)

    $item = Get-Item -LiteralPath $JunctionPath -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
        throw 'fixture-only junction 清理拒绝非重解析目录'
    }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'C:\Windows\System32\cmd.exe'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    [void]$start.ArgumentList.Add('/d')
    [void]$start.ArgumentList.Add('/c')
    [void]$start.ArgumentList.Add('rmdir')
    [void]$start.ArgumentList.Add($JunctionPath)
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'fixture-only junction 清理进程启动失败' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(5000)) {
            try { $process.Kill($true) } catch {}
            [void]$process.WaitForExit(1000)
            throw 'fixture-only junction 清理超时'
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0 -or (Test-Path -LiteralPath $JunctionPath)) {
            throw "fixture-only junction 清理失败：exit=$($process.ExitCode); stdout=$($stdout.Trim()); stderr=$($stderr.Trim())"
        }
    } finally { $process.Dispose() }
}

function Invoke-FixtureManagedParentAttack {
    param([string]$TargetParent)

    if ($null -eq $script:FixtureManagedParentAttack -or $TargetParent -ine [string]$script:FixtureManagedParentAttack.targetParent) { return }
    $attack = $script:FixtureManagedParentAttack
    $script:FixtureManagedParentAttack = $null
    Move-Item -LiteralPath $TargetParent -Destination ([string]$attack.movedParent)
    try {
        New-FixtureJunction -JunctionPath $TargetParent -TargetPath ([string]$attack.externalParent)
    } catch {
        $originalFailure = $_
        if (Test-Path -LiteralPath $TargetParent) { Remove-FixtureJunction -JunctionPath $TargetParent }
        if ((Test-Path -LiteralPath ([string]$attack.movedParent) -PathType Container) -and -not (Test-Path -LiteralPath $TargetParent)) {
            Move-Item -LiteralPath ([string]$attack.movedParent) -Destination $TargetParent
        }
        throw $originalFailure
    }
}

function Invoke-FixtureCreatedDirectoryCleanupReplace {
    param([string]$TargetParent)

    if ($null -eq $script:FixtureCreatedDirectoryCleanupReplace -or $TargetParent -ine [string]$script:FixtureCreatedDirectoryCleanupReplace.targetParent) { return }
    $replace = $script:FixtureCreatedDirectoryCleanupReplace
    $script:FixtureCreatedDirectoryCleanupReplace = $null
    Move-Item -LiteralPath $TargetParent -Destination ([string]$replace.movedParent)
    try {
        New-FixtureJunction -JunctionPath $TargetParent -TargetPath ([string]$replace.externalParent)
    } catch {
        $originalFailure = $_
        if (Test-Path -LiteralPath $TargetParent) { Remove-FixtureJunction -JunctionPath $TargetParent }
        if ((Test-Path -LiteralPath ([string]$replace.movedParent) -PathType Container) -and -not (Test-Path -LiteralPath $TargetParent)) {
            Move-Item -LiteralPath ([string]$replace.movedParent) -Destination $TargetParent
        }
        throw $originalFailure
    }
}

function Invoke-FixtureLegacyDeleteReplace {
    param([string]$TargetPath)

    if ($null -eq $script:FixtureLegacyDeleteReplace -or $TargetPath -ine [string]$script:FixtureLegacyDeleteReplace.targetPath) { return }
    $replace = $script:FixtureLegacyDeleteReplace
    $script:FixtureLegacyDeleteReplace = $null
    $parent = Split-Path -Parent $TargetPath
    $guard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire($parent, $parent, $false)
    $tempPath = Join-Path $parent ".legacy-attack-$([guid]::NewGuid().ToString('N')).tmp"
    $temp = $null
    try {
        $temp = $guard.CreateTempFile($tempPath)
        $temp.WriteAndFlush([Text.UTF8Encoding]::new($false).GetBytes([string]$replace.replacementContent))
        $temp.RenameTo($TargetPath, $true)
    } finally {
        if ($null -ne $temp) { $temp.Dispose() }
        $guard.Dispose()
        if ([IO.File]::Exists($tempPath)) { [IO.File]::Delete($tempPath) }
    }
}

function Invoke-FixtureLegacyDirectoryReplace {
    param(
        [string]$TargetPath,
        [ValidateSet('delete')][string]$Phase
    )

    $replace = $script:FixtureLegacyDirectoryDeleteReplace
    if ($null -eq $replace -or $TargetPath -ine [string]$replace.targetPath) { return }
    $script:FixtureLegacyDirectoryDeleteReplace = $null
    Move-Item -LiteralPath $TargetPath -Destination ([string]$replace.movedPath)
    try { New-FixtureJunction -JunctionPath $TargetPath -TargetPath ([string]$replace.externalParent) }
    catch {
        $failure = $_
        if (Test-Path -LiteralPath $TargetPath) { Remove-FixtureJunction -JunctionPath $TargetPath }
        if ((Test-Path -LiteralPath ([string]$replace.movedPath) -PathType Container) -and -not (Test-Path -LiteralPath $TargetPath)) { Move-Item -LiteralPath ([string]$replace.movedPath) -Destination $TargetPath }
        throw $failure
    }
}

function Invoke-FixtureEvidenceAncestorReplace {
    param([string]$ProtectedParent)

    $replace = $script:FixtureEvidenceAncestorReplace
    if ($null -eq $replace -or -not ([IO.Path]::GetFullPath($ProtectedParent).TrimEnd('\')).StartsWith(([string]$replace.targetParent), [StringComparison]::OrdinalIgnoreCase)) { return }
    $script:FixtureEvidenceAncestorReplace = $null
    Move-Item -LiteralPath ([string]$replace.targetParent) -Destination ([string]$replace.movedParent)
    try { New-FixtureJunction -JunctionPath ([string]$replace.targetParent) -TargetPath ([string]$replace.externalParent) }
    catch {
        $failure = $_
        if (Test-Path -LiteralPath ([string]$replace.targetParent)) { Remove-FixtureJunction -JunctionPath ([string]$replace.targetParent) }
        if ((Test-Path -LiteralPath ([string]$replace.movedParent) -PathType Container) -and -not (Test-Path -LiteralPath ([string]$replace.targetParent))) { Move-Item -LiteralPath ([string]$replace.movedParent) -Destination ([string]$replace.targetParent) }
        throw $failure
    }
}

function Invoke-FixtureAclCasReplace {
    param([string]$TargetPath)

    if ($null -eq $script:FixtureAclCasReplace -or $TargetPath -ine [string]$script:FixtureAclCasReplace) { return }
    $script:FixtureAclCasReplace = $null
    $acl = Get-Acl -LiteralPath $TargetPath
    $acl.SetAccessRuleProtection(-not [bool]$acl.AreAccessRulesProtected, $true)
    Set-Acl -LiteralPath $TargetPath -AclObject $acl
}

function Invoke-FixtureRollbackAclCasReplace {
    param([string]$TargetPath)

    if ($null -eq $script:FixtureRollbackAclCasReplace -or $TargetPath -ine [string]$script:FixtureRollbackAclCasReplace) { return }
    $script:FixtureRollbackAclCasReplace = $null
    $acl = Get-Acl -LiteralPath $TargetPath
    $acl.SetAccessRuleProtection(-not [bool]$acl.AreAccessRulesProtected, $true)
    Set-Acl -LiteralPath $TargetPath -AclObject $acl
}


function Get-ManagedHookFileStates {
    param([string]$ResolvedCodexHome)

    $managedRoot = [System.IO.Path]::GetFullPath([string]$script:HostPreflightManifest.managedRoot).TrimEnd('\', '/')
    $expectedManagedRoot = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $PSScriptRoot) 'managed\codex-hooks')).TrimEnd('\', '/')
    if (-not $managedRoot.Equals($expectedManagedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'host preflight manifest managedRoot 未绑定当前项目受管源'
    }
    $hookDirectory = Join-Path $ResolvedCodexHome 'hooks'
    @($script:HostPreflightManifest.files | ForEach-Object {
        $sourcePath = [System.IO.Path]::GetFullPath((Join-Path $managedRoot ([string]$_.relativePath)))
        if (-not $sourcePath.StartsWith("$managedRoot\", [System.StringComparison]::OrdinalIgnoreCase)) { throw '受管 source 路径越界' }
        Assert-NoReparsePath -Path $sourcePath -RequireLeaf | Out-Null
        $sourceSnapshot = Get-CodexHookHandleBoundFileSnapshot -Path $sourcePath -Name "managed source $($_.relativePath)" -AllowedExactPaths @($sourcePath)
        if (-not $sourceSnapshot.probe.safeToRead) { throw "受管 source 无法安全读取：$($_.relativePath) state=$($sourceSnapshot.probe.state)" }
        [byte[]]$sourceBytes = [byte[]]$sourceSnapshot.bytes
        $sourceRawSha256 = (Get-CodexHookBytesSha256 -Bytes $sourceBytes).ToLowerInvariant()
        $sourceCanonicalSha256 = (Get-CodexHookManifestSourceSha256 -Bytes $sourceBytes).ToLowerInvariant()
        if ($sourceCanonicalSha256 -cne ([string]$_.sha256).ToLowerInvariant()) { throw "受管 source canonical hash 漂移：$($_.relativePath)" }
        $targetPath = [System.IO.Path]::GetFullPath((Join-Path $hookDirectory ([string]$_.liveRelativePath)))
        if (-not $targetPath.StartsWith("$hookDirectory\", [System.StringComparison]::OrdinalIgnoreCase)) { throw '受管 live 路径越界' }
        $targetExists = Test-Path -LiteralPath $targetPath -PathType Leaf
        if ($targetExists) { Assert-NoReparsePath -Path $targetPath -RequireLeaf | Out-Null }
        $targetRawSha256 = if ($targetExists) { (Get-Sha256 -Path $targetPath).ToLowerInvariant() } else { $null }
        [pscustomobject]@{
            relativePath = [string]$_.relativePath
            liveRelativePath = [string]$_.liveRelativePath
            sourcePath = $sourcePath
            sourceBytes = $sourceBytes
            sourceCanonicalSha256 = $sourceCanonicalSha256
            sourceRawSha256 = $sourceRawSha256
            targetPath = $targetPath
            targetParentPath = Split-Path -Parent $targetPath
            targetParentExisted = Test-Path -LiteralPath (Split-Path -Parent $targetPath) -PathType Container
            targetExists = $targetExists
            targetRawSha256 = $targetRawSha256
            ok = $targetExists -and $targetRawSha256 -ceq $sourceRawSha256
        }
    })
}

function Test-ManagedHookFileIsWrapper {
    param([Parameter(Mandatory)][string]$LiveRelativePath)

    $normalized = $LiveRelativePath.Replace('/', '\')
    $liveHooksRoot = [IO.Path]::GetFullPath('D:\Codex\.codex\hooks').TrimEnd('\')
    foreach ($hook in @($script:HostPreflightManifest.hooks)) {
        $wrapperPath = [IO.Path]::GetFullPath([string]$hook.wrapperPath)
        $relativeWrapperPath = [IO.Path]::GetRelativePath($liveHooksRoot, $wrapperPath).Replace('/', '\')
        if ($relativeWrapperPath -ceq $normalized) { return $true }
    }
    return $false
}

function Get-OrderedManagedHookItems {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory)][ValidateSet('Repair','Restore')][string]$Direction
    )

    $wrappers = @($Items | Where-Object { Test-ManagedHookFileIsWrapper -LiveRelativePath ([string]$_.liveRelativePath) })
    $dependencies = @($Items | Where-Object { -not (Test-ManagedHookFileIsWrapper -LiveRelativePath ([string]$_.liveRelativePath)) })
    if ($Direction -ceq 'Repair') {
        $dependencies
        $wrappers
    } else {
        $wrappers
        $dependencies
    }
}

function Get-HostRuntimeDependencyStates {
    param([Parameter(Mandatory)][string]$ResolvedCodexHome)

    $requestedMissingRuntimeId = $env:CODEX_HOST_HOOK_TEST_MISSING_RUNTIME_ID
    if (-not [string]::IsNullOrWhiteSpace($requestedMissingRuntimeId)) {
        if ($requestedMissingRuntimeId -cne 'pythonw') {
            throw 'fixture-only missing runtime id 只允许 pythonw'
        }
        if (Test-IsLiveCodexHome -ResolvedCodexHome $ResolvedCodexHome) {
            throw 'fixture-only missing runtime seam 不得用于 live CodexHome'
        }
        Assert-RepairHomeAuthorized -ResolvedCodexHome $ResolvedCodexHome
    }

    $runtimeIds = [Collections.Generic.List[string]]::new()
    $seenRuntimeIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($hook in @($script:HostPreflightManifest.hooks)) {
        foreach ($runtimeId in @([string]$hook.runtimeId, [string]$hook.launcherRuntimeId)) {
            if (-not [string]::IsNullOrEmpty($runtimeId) -and $seenRuntimeIds.Add($runtimeId)) {
                $runtimeIds.Add($runtimeId)
            }
        }
    }

    foreach ($runtimeId in $runtimeIds) {
        $runtimeProperty = $script:HostPreflightManifest.runtimes.PSObject.Properties[$runtimeId]
        if ($null -eq $runtimeProperty) { throw "host runtime dependency 未声明：$runtimeId" }
        $runtimePath = [IO.Path]::GetFullPath([string]$runtimeProperty.Value)
        $observation = Get-CodexHookSafeFileHash `
            -Path $runtimePath `
            -Name "host runtime dependency $runtimeId" `
            -AllowedExactPaths @($runtimePath)
        $simulatedMissing = $runtimeId -ceq $requestedMissingRuntimeId
        [pscustomobject][ordered]@{
            id = $runtimeId
            path = $runtimePath
            exists = if ($simulatedMissing) { $false } else { [bool]$observation.probe.exists }
            probeState = if ($simulatedMissing) { 'missing-fixture' } else { [string]$observation.probe.state }
            sha256 = if ($simulatedMissing) { $null } else { $observation.sha256 }
            ok = -not $simulatedMissing -and [bool]$observation.probe.safeToRead -and [string]$observation.sha256 -cmatch '^[0-9a-f]{64}$'
        }
    }
}

function Test-IsLiveCodexHome {
    param([string]$ResolvedCodexHome)
    $ResolvedCodexHome.Equals([System.IO.Path]::GetFullPath('D:\Codex\.codex').TrimEnd('\', '/'), [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-SerenaEnvironmentState {
    param([string]$ResolvedCodexHome)

    $desired = 'D:\Codex\.serena'
    if (Test-IsLiveCodexHome -ResolvedCodexHome $ResolvedCodexHome) {
        $snapshot = [CodexHookGovernance.UserEnvironmentTransaction]::ReadUserSerenaHome()
        $value = $snapshot.Value
        $valueKind = $snapshot.Kind.ToString()
        return [pscustomobject]@{ value = $value; valueKind = $valueKind; desired = $desired; ok = $value -ceq $desired -and $valueKind -ceq 'String'; fixturePath = $null; fixtureContent = $null; fixtureSha256 = $null; fixtureSddl = $null }
    }
    $fixturePath = Join-Path $ResolvedCodexHome '.fixture-user-environment.json'
    Assert-NoReparsePath -Path $fixturePath -RequireLeaf | Out-Null
    $fixtureContent = Read-Text -Path $fixturePath
    $document = $fixtureContent | ConvertFrom-Json
    if (@($document.PSObject.Properties.Name | Where-Object { $_ -cne 'SERENA_HOME' }).Count -ne 0) { throw 'fixture User 环境存根包含未知字段' }
    [pscustomobject]@{ value = [string]$document.SERENA_HOME; valueKind = 'String'; desired = $desired; ok = ([string]$document.SERENA_HOME) -ceq $desired; fixturePath = $fixturePath; fixtureContent = $fixtureContent; fixtureSha256 = Get-Sha256 -Path $fixturePath; fixtureSddl = (Get-Acl -LiteralPath $fixturePath).Sddl }
}

function Set-SerenaEnvironmentValue {
    param(
        [string]$ResolvedCodexHome,
        [AllowNull()][string]$Value,
        [AllowNull()][string]$ExpectedValue,
        [ValidateSet('Missing', 'String', 'ExpandString')][string]$ValueKind = 'String',
        [ValidateSet('Missing', 'String', 'ExpandString')][string]$ExpectedValueKind = 'String'
    )

    $current = Get-SerenaEnvironmentState -ResolvedCodexHome $ResolvedCodexHome
    if ([string]$current.value -cne [string]$ExpectedValue -or [string]$current.valueKind -cne $ExpectedValueKind) { throw 'SERENA_HOME 在提交前发生并发变化' }
    if (Test-IsLiveCodexHome -ResolvedCodexHome $ResolvedCodexHome) {
        $expectedKind = [enum]::Parse([CodexHookGovernance.UserEnvironmentValueKind], $ExpectedValueKind, $false)
        $desiredKind = [enum]::Parse([CodexHookGovernance.UserEnvironmentValueKind], $ValueKind, $false)
        $expectedArgument = if ($ExpectedValueKind -ceq 'Missing') { [System.Management.Automation.Language.NullString]::Value } else { $ExpectedValue }
        $desiredArgument = if ($ValueKind -ceq 'Missing') { [System.Management.Automation.Language.NullString]::Value } else { $Value }
        [CodexHookGovernance.UserEnvironmentTransaction]::SetUserSerenaHome($expectedArgument, $expectedKind, $desiredArgument, $desiredKind)
    } else {
        if ($ValueKind -cne 'String' -or $ExpectedValueKind -cne 'String') { throw 'fixture User 环境仅允许 String 类型' }
        $content = ([ordered]@{ SERENA_HOME = $Value } | ConvertTo-Json -Compress) + "`n"
        Write-AtomicText -Path ([string]$current.fixturePath) -Content $content -ExpectedCurrentSha256 (Get-Sha256 -Path ([string]$current.fixturePath)) -ExpectedCurrentSddl (Get-Acl -LiteralPath ([string]$current.fixturePath)).Sddl
    }
    $after = Get-SerenaEnvironmentState -ResolvedCodexHome $ResolvedCodexHome
    if ([string]$after.value -cne [string]$Value -or [string]$after.valueKind -cne $ValueKind) { throw 'SERENA_HOME 写后校验失败' }
}

function Get-TomlKeyIndices {
    param([object]$Document,[string]$Key,[int]$Start,[int]$End)
    $expectedSegments = @($Key)
    @(
        for ($index = $Start; $index -lt $End; $index++) {
            $segments = @(Get-TomlAssignmentKeySegments -Line $Document.lines[$index])
            if (Test-TomlKeySegmentsEqual -Left $segments -Right $expectedSegments) { $index }
        }
    )
}

function Get-OptionalTomlBooleanKeyValue {
    param(
        [object]$Document,
        [string]$Key,
        [int]$Start,
        [int]$End,
        [string]$Scope
    )

    $indices = @(Get-TomlKeyIndices -Document $Document -Key $Key -Start $Start -End $End)
    if ($indices.Count -gt 1) {
        throw "TOML boolean key 在 $Scope 中重复：$Key"
    }
    if ($indices.Count -eq 0) { return $null }

    $line = [string]$Document.lines[$indices[0]]
    $equalsIndex = $line.IndexOf('=')
    if ($equalsIndex -lt 0) { throw "无法解析 TOML boolean key：$Key" }
    $match = [regex]::Match($line.Substring($equalsIndex + 1).Trim(), '^(?<value>true|false)\s*(?:#.*)?$')
    if (-not $match.Success) {
        throw "TOML boolean key 必须为 true 或 false：$Scope.$Key"
    }
    return [bool]::Parse($match.Groups['value'].Value)
}

function Set-TomlKeyLiteral {
    param(
        [object]$Document,
        [int]$Index,
        [string]$Key,
        [string]$Literal
    )

    $match = [regex]::Match($Document.lines[$Index], '^(?<indent>\s*)')
    if (-not $match.Success) {
        throw "无法定位 TOML key：$Key"
    }
    $Document.lines[$Index] = "$($match.Groups['indent'].Value)$Key = $Literal"
}

function ConvertFrom-SingleLineTomlStringArray {
    param([string]$Literal)

    $text = $Literal.Trim()
    if (-not $text.StartsWith('[') -or -not $text.EndsWith(']')) {
        throw 'TOML 字符串数组必须使用单行 []。'
    }

    $items = [Collections.Generic.List[string]]::new()
    $index = 1
    while ($index -lt ($text.Length - 1)) {
        while ($index -lt ($text.Length - 1) -and [char]::IsWhiteSpace($text[$index])) { $index++ }
        if ($index -ge ($text.Length - 1)) { break }
        if ($text[$index] -eq ',') { throw 'TOML 字符串数组包含空元素。' }

        $quote = $text[$index]
        if ($quote -ne "'" -and $quote -ne '"') {
            throw 'TOML 字符串数组只能包含字符串元素。'
        }
        $start = $index
        $index++

        if ($quote -eq "'") {
            $valueStart = $index
            while ($index -lt $text.Length -and $text[$index] -ne "'") {
                if ($text[$index] -eq "`r" -or $text[$index] -eq "`n") { throw 'TOML 字符串数组必须是单行。' }
                $index++
            }
            if ($index -ge $text.Length) { throw 'TOML literal string 未闭合。' }
            $items.Add($text.Substring($valueStart, $index - $valueStart))
            $index++
        } else {
            $escaped = $false
            while ($index -lt $text.Length) {
                $ch = $text[$index]
                if ($ch -eq "`r" -or $ch -eq "`n") { throw 'TOML 字符串数组必须是单行。' }
                if ($escaped) {
                    $escaped = $false
                } elseif ($ch -eq '\') {
                    $escaped = $true
                } elseif ($ch -eq '"') {
                    break
                }
                $index++
            }
            if ($index -ge $text.Length) { throw 'TOML basic string 未闭合。' }
            $jsonString = $text.Substring($start, ($index - $start) + 1)
            try {
                $items.Add([string](ConvertFrom-Json -InputObject $jsonString -NoEnumerate))
            } catch {
                throw "TOML basic string escape 非法：$($_.Exception.Message)"
            }
            $index++
        }

        while ($index -lt ($text.Length - 1) -and [char]::IsWhiteSpace($text[$index])) { $index++ }
        if ($index -ge ($text.Length - 1)) { break }
        if ($text[$index] -ne ',') { throw 'TOML 字符串数组元素之间必须用逗号分隔。' }
        $index++
        while ($index -lt ($text.Length - 1) -and [char]::IsWhiteSpace($text[$index])) { $index++ }
        if ($index -ge ($text.Length - 1)) { throw 'TOML 字符串数组不得有尾随逗号。' }
    }

    return [string[]]$items.ToArray()
}

function ConvertFrom-SingleLineTomlString {
    param([string]$Literal)

    $items = @(ConvertFrom-SingleLineTomlStringArray -Literal ("[$Literal]"))
    if ($items.Count -ne 1) {
        throw 'TOML value 必须是单个字符串。'
    }
    [string]$items[0]
}

function Convert-SerenaArgs {
    param(
        [string]$RightHandSide,
        [string]$ExpectedContextPath
    )

    try {
        $tokens = @(ConvertFrom-SingleLineTomlStringArray -Literal $RightHandSide)
    } catch {
        throw "Serena args 必须是单行 TOML 字符串数组：$($_.Exception.Message)"
    }
    # Codex Desktop 26.825 起官方把 .cmd 形态的 MCP 条目迁移为
    # cmd.exe /c <受管 wrapper> start-mcp-server ...；两种入口形态都接受，
    # canonical 输出统一为官方包装形态。
    $wrapperScript = 'D:\Codex\.codex\scripts\start-serena-mcp.cmd'
    $serenaStartIndex = -1
    if ($tokens.Count -gt 0 -and [string]$tokens[0] -ceq "start-mcp-server") {
        $serenaStartIndex = 0
    } elseif ($tokens.Count -ge 3 -and [string]$tokens[0] -ceq "/c" -and [string]$tokens[1] -ceq $wrapperScript -and [string]$tokens[2] -ceq "start-mcp-server") {
        $serenaStartIndex = 2
    }
    if ($serenaStartIndex -lt 0) {
        throw "Serena args 必须以 start-mcp-server 开头（官方 cmd.exe /c 受管包装亦可）"
    }
    foreach ($token in $tokens) {
        if ($token -isnot [string]) {
            throw "Serena args 只能包含字符串"
        }
    }

    $result = [System.Collections.Generic.List[string]]::new()
    $contextValues = [System.Collections.Generic.List[string]]::new()
    for ($index = $serenaStartIndex; $index -lt $tokens.Count; $index++) {
        $token = [string]$tokens[$index]
        if ($token.StartsWith("--project-from-cwd=", [StringComparison]::Ordinal)) {
            throw "--project-from-cwd 不接受值"
        }
        if ($token -ceq "--context") {
            if ($index + 1 -ge $tokens.Count -or
                [string]::IsNullOrWhiteSpace([string]$tokens[$index + 1]) -or
                ([string]$tokens[$index + 1]).StartsWith("--", [System.StringComparison]::Ordinal)) {
                throw "--context 缺少参数值"
            }
            $contextValues.Add([string]$tokens[$index + 1])
        }
        if ($token.StartsWith("--context=", [System.StringComparison]::Ordinal)) {
            $contextValue = $token.Substring("--context=".Length)
            if ([string]::IsNullOrWhiteSpace($contextValue)) {
                throw "--context 缺少参数值"
            }
            $contextValues.Add($contextValue)
        }
        if ($token -ceq "--project" -or $token -ceq "--project-file") {
            if ($index + 1 -ge $tokens.Count -or
                [string]::IsNullOrWhiteSpace([string]$tokens[$index + 1]) -or
                ([string]$tokens[$index + 1]).StartsWith("--", [System.StringComparison]::Ordinal)) {
                throw "$token 缺少参数值"
            }
            $index++
            continue
        }
        if ($token.StartsWith("--project=", [System.StringComparison]::Ordinal) -or $token.StartsWith("--project-file=", [System.StringComparison]::Ordinal)) {
            if ([string]::IsNullOrWhiteSpace($token.Substring($token.IndexOf('=') + 1))) {
                throw "$($token.Substring(0, $token.IndexOf('='))) 缺少参数值"
            }
            continue
        }

        $result.Add($token)
    }

    if ($contextValues.Count -ne 1) {
        throw "Serena args 必须恰好包含一个 --context；实际 $($contextValues.Count)"
    }
    if (-not [System.IO.Path]::IsPathFullyQualified($contextValues[0])) {
        throw "Serena --context 必须是绝对路径：$($contextValues[0])"
    }
    $resolvedContext = [System.IO.Path]::GetFullPath($contextValues[0]).TrimEnd('\', '/')
    $resolvedExpected = [System.IO.Path]::GetFullPath($ExpectedContextPath).TrimEnd('\', '/')
    if (-not $resolvedContext.Equals($resolvedExpected, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Serena --context 未指向受保护的 codex-file-tools.yml"
    }

    $result.Insert(0, $wrapperScript)
    $result.Insert(0, "/c")
    ConvertTo-Json -InputObject $result.ToArray() -Compress
}

function Test-ProjectTrustPathUsesExtendedOrDevicePrefix {
    param([Parameter(Mandatory)][string]$Path)

    # Windows accepts slash and mixed-separator spellings for extended/device
    # paths. Normalize separators before testing so GetFullPath never receives
    # an alias that can evade this fail-closed boundary.
    $normalizedPath = $Path.Replace('/', '\')
    return (
        $normalizedPath.StartsWith('\\?\', [StringComparison]::Ordinal) -or
        $normalizedPath.StartsWith('\\.\', [StringComparison]::Ordinal)
    )
}

function ConvertTo-CanonicalManagedProjectTrustPath {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$Role
    )

    if (Test-ProjectTrustPathUsesExtendedOrDevicePrefix -Path $ProjectPath) {
        throw 'unsupported-extended-project-trust-path'
    }
    try {
        $canonicalPath = [IO.Path]::GetFullPath($ProjectPath).TrimEnd('\', '/')
    } catch {
        throw "$Role 路径无法规范化：$ProjectPath"
    }
    $managedProjectRoots = @('D:\Codex\projects', 'D:\agents\projects')
    $canonicalInManagedRoot = $false
    foreach ($managedProjectRoot in $managedProjectRoots) {
        if (-not $canonicalPath.Equals($managedProjectRoot, [StringComparison]::OrdinalIgnoreCase) -and
            $canonicalPath.StartsWith("$managedProjectRoot\", [StringComparison]::OrdinalIgnoreCase)) {
            $canonicalInManagedRoot = $true
            break
        }
    }
    if (-not $canonicalInManagedRoot) {
        throw "$Role 路径不在项目根下（D:\Codex\projects 或 D:\agents\projects 的非集合根）：$ProjectPath"
    }
    return $canonicalPath
}

function Get-CanonicalRetiredProjectTrustPaths {
    param([Parameter(Mandatory)][string[]]$RetiredProjectTrusts)

    $retiredProjectPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($projectPath in $RetiredProjectTrusts) {
        $canonicalPath = ConvertTo-CanonicalManagedProjectTrustPath -ProjectPath $projectPath -Role '退役 project trust'
        if (-not $retiredProjectPaths.Add($canonicalPath)) {
            throw "退役 project trust 路径重复：$canonicalPath"
        }
    }
    Write-Output -NoEnumerate $retiredProjectPaths
}

function Test-IsRetiredProjectTrustPathSegments {
    param(
        [Parameter(Mandatory)][string[]]$Segments,
        [Parameter(Mandatory)][Collections.Generic.HashSet[string]]$RetiredProjectPaths
    )

    if ($Segments.Count -lt 2 -or [string]$Segments[0] -cne 'projects') {
        return $false
    }

    $candidatePath = [string]$Segments[1]
    if (Test-ProjectTrustPathUsesExtendedOrDevicePrefix -Path $candidatePath) {
        throw 'unsupported-extended-project-trust-path'
    }
    if (-not [IO.Path]::IsPathFullyQualified($candidatePath)) {
        return $false
    }
    try {
        $candidatePath = [IO.Path]::GetFullPath($candidatePath).TrimEnd('\', '/')
    } catch {
        return $false
    }
    return $RetiredProjectPaths.Contains($candidatePath)
}

function Get-TomlInlineTableTopLevelEntries {
    param([Parameter(Mandatory)][string]$Value)

    $text = $Value.Trim()
    if (-not $text.StartsWith('{', [StringComparison]::Ordinal)) {
        return @()
    }

    # The whole document has already passed tomllib validation. This lexer
    # identifies inline-table keys semantically instead of raw-path searching.
    $entries = [Collections.Generic.List[object]]::new()
    $index = 1
    $closed = $false
    while (-not $closed) {
        while ($index -lt $text.Length -and [char]::IsWhiteSpace($text[$index])) {
            $index++
        }
        if ($index -ge $text.Length) {
            throw 'unsupported-inline-retired-project-trust'
        }
        if ($text[$index] -eq [char]'}') {
            $index++
            $closed = $true
            break
        }

        $keyStart = $index
        $inBasicString = $false
        $inLiteralString = $false
        $escaped = $false
        $foundEquals = $false
        while ($index -lt $text.Length) {
            $character = $text[$index]
            if ($inBasicString) {
                if ($escaped) {
                    $escaped = $false
                } elseif ($character -eq [char]'\') {
                    $escaped = $true
                } elseif ($character -eq [char]'"') {
                    $inBasicString = $false
                }
            } elseif ($inLiteralString) {
                if ($character -eq [char]"'") {
                    $inLiteralString = $false
                }
            } else {
                if ($character -eq [char]'"') {
                    $inBasicString = $true
                } elseif ($character -eq [char]"'") {
                    $inLiteralString = $true
                } elseif ($character -eq [char]'=') {
                    $foundEquals = $true
                    break
                } elseif ($character -eq [char]',' -or $character -eq [char]'}') {
                    throw 'unsupported-inline-retired-project-trust'
                }
            }
            $index++
        }
        if (-not $foundEquals) {
            throw 'unsupported-inline-retired-project-trust'
        }

        $keyText = $text.Substring($keyStart, $index - $keyStart).Trim()
        if ([string]::IsNullOrWhiteSpace($keyText)) {
            throw 'unsupported-inline-retired-project-trust'
        }
        $entries.Add([pscustomobject]@{
            segments = @(ConvertFrom-TomlDottedKeyName -Name $keyText)
        })

        $index++
        $nestedBraces = 0
        $squareDepth = 0
        $inBasicString = $false
        $inLiteralString = $false
        $escaped = $false
        $entryTerminated = $false
        while ($index -lt $text.Length) {
            $character = $text[$index]
            if ($inBasicString) {
                if ($escaped) {
                    $escaped = $false
                } elseif ($character -eq [char]'\') {
                    $escaped = $true
                } elseif ($character -eq [char]'"') {
                    $inBasicString = $false
                }
                $index++
                continue
            }
            if ($inLiteralString) {
                if ($character -eq [char]"'") {
                    $inLiteralString = $false
                }
                $index++
                continue
            }

            if ($character -eq [char]'"') {
                $inBasicString = $true
                $index++
                continue
            }
            if ($character -eq [char]"'") {
                $inLiteralString = $true
                $index++
                continue
            }
            if ($character -eq [char]'{') {
                $nestedBraces++
                $index++
                continue
            }
            if ($character -eq [char]'}') {
                if ($nestedBraces -gt 0) {
                    $nestedBraces--
                    $index++
                    continue
                }
                if ($squareDepth -ne 0) {
                    throw 'unsupported-inline-retired-project-trust'
                }
                $index++
                $entryTerminated = $true
                $closed = $true
                break
            }
            if ($character -eq [char]'[') {
                $squareDepth++
                $index++
                continue
            }
            if ($character -eq [char]']') {
                if ($squareDepth -le 0) {
                    throw 'unsupported-inline-retired-project-trust'
                }
                $squareDepth--
                $index++
                continue
            }
            if ($character -eq [char]',' -and $nestedBraces -eq 0 -and $squareDepth -eq 0) {
                $index++
                $entryTerminated = $true
                break
            }
            if ($character -eq [char]'#' -and $nestedBraces -eq 0 -and $squareDepth -eq 0) {
                throw 'unsupported-inline-retired-project-trust'
            }
            $index++
        }
        if (-not $entryTerminated) {
            throw 'unsupported-inline-retired-project-trust'
        }
    }

    $trailing = $text.Substring($index).Trim()
    if (-not [string]::IsNullOrWhiteSpace($trailing) -and -not $trailing.StartsWith('#', [StringComparison]::Ordinal)) {
        throw 'unsupported-inline-retired-project-trust'
    }
    return $entries.ToArray()
}

function Test-InlineProjectsValueContainsRetiredProjectTrust {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][Collections.Generic.HashSet[string]]$RetiredProjectPaths
    )

    if (-not $Value.TrimStart().StartsWith('{', [StringComparison]::Ordinal)) {
        return $false
    }
    foreach ($entry in @(Get-TomlInlineTableTopLevelEntries -Value $Value)) {
        $effectiveSegments = @('projects') + @($entry.segments)
        if (Test-IsRetiredProjectTrustPathSegments -Segments $effectiveSegments -RetiredProjectPaths $RetiredProjectPaths) {
            return $true
        }
    }
    return $false
}

function Assert-RetiredProjectTrustAssignmentIsSingleLine {
    param([Parameter(Mandatory)][string]$Line)

    # Deleting only the first line of a multiline value could orphan a TOML
    # continuation, so accept a targeted dotted assignment only when it parses
    # as a complete standalone TOML document.
    try {
        Assert-ValidToml -Content $Line
    } catch {
        throw 'unsupported-multiline-retired-project-trust'
    }
}

function Test-IsRetiredProjectTrustHeader {
    param(
        [Parameter(Mandatory)][object]$Header,
        [Parameter(Mandatory)][Collections.Generic.HashSet[string]]$RetiredProjectPaths
    )

    if ($Header.kind -cne 'table' -and $Header.kind -cne 'array-table') {
        return $false
    }
    return Test-IsRetiredProjectTrustPathSegments -Segments @($Header.segments) -RetiredProjectPaths $RetiredProjectPaths
}

function Remove-RetiredProjectTrustBlocks {
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][Collections.Generic.HashSet[string]]$RetiredProjectPaths
    )

    $document = Get-TomlDocument -Content $Content
    $headers = @($document.headers | Sort-Object index)
    $lineStarts = [Collections.Generic.List[int]]::new()
    $lineStarts.Add(0)
    for ($offset = 0; $offset -lt $Content.Length; $offset++) {
        if ($Content[$offset] -eq "`n") {
            $lineStarts.Add($offset + 1)
        }
    }
    if ($lineStarts.Count -ne $document.lines.Count) {
        throw 'TOML 行偏移与结构化 header 索引不一致，拒绝删除退役 project trust。'
    }

    $removeLines = [bool[]]::new($document.lines.Count)
    for ($headerIndex = 0; $headerIndex -lt $headers.Count; $headerIndex++) {
        $header = $headers[$headerIndex]
        if (-not (Test-IsRetiredProjectTrustHeader -Header $header -RetiredProjectPaths $RetiredProjectPaths)) {
            continue
        }
        $startLine = [int]$header.index
        $endLine = if ($headerIndex + 1 -lt $headers.Count) { [int]$headers[$headerIndex + 1].index } else { $document.lines.Count }
        if ($startLine -lt 0 -or $endLine -lt $startLine -or $startLine -ge $lineStarts.Count -or $endLine -gt $lineStarts.Count) {
            throw '退役 project trust 的 TOML header 范围非法。'
        }
        for ($lineIndex = $startLine; $lineIndex -lt $endLine; $lineIndex++) {
            $removeLines[$lineIndex] = $true
        }
    }

    # TOML permits the same project path to appear as a dotted assignment
    # instead of a table header. Resolve each assignment against its current
    # header context, then remove only complete single-line assignments that
    # semantically belong to a retired project. Do not raw-search paths.
    $currentHeader = $null
    $nextHeaderIndex = 0
    for ($lineIndex = 0; $lineIndex -lt $document.lines.Count; $lineIndex++) {
        while ($nextHeaderIndex -lt $headers.Count -and [int]$headers[$nextHeaderIndex].index -le $lineIndex) {
            $currentHeader = $headers[$nextHeaderIndex]
            $nextHeaderIndex++
        }
        if ($removeLines[$lineIndex]) {
            continue
        }

        $assignment = Get-TomlAssignmentParts -Line $document.lines[$lineIndex]
        if ($null -eq $assignment) {
            continue
        }
        $assignmentSegments = @($assignment.segments)
        if ($assignmentSegments.Count -eq 0) {
            continue
        }
        $effectiveSegments = if ($null -eq $currentHeader) {
            @($assignmentSegments)
        } else {
            @($currentHeader.segments) + @($assignmentSegments)
        }
        if (Test-IsRetiredProjectTrustPathSegments -Segments $effectiveSegments -RetiredProjectPaths $RetiredProjectPaths) {
            Assert-RetiredProjectTrustAssignmentIsSingleLine -Line $document.lines[$lineIndex]
            $removeLines[$lineIndex] = $true
            continue
        }

        # A root projects inline table can mix retired and unrelated entries.
        # Rewriting it would risk discarding a user entry, so reject it rather
        # than silently preserving a retired trust or normalizing user data.
        if (
            $null -eq $currentHeader -and
            (Test-TomlKeySegmentsEqual -Left $assignmentSegments -Right @('projects')) -and
            (Test-InlineProjectsValueContainsRetiredProjectTrust -Value ([string]$assignment.value) -RetiredProjectPaths $RetiredProjectPaths)
        ) {
            throw 'unsupported-inline-retired-project-trust'
        }
    }

    $ranges = [Collections.Generic.List[object]]::new()
    $lineIndex = 0
    while ($lineIndex -lt $removeLines.Count) {
        if (-not $removeLines[$lineIndex]) {
            $lineIndex++
            continue
        }
        $startLine = $lineIndex
        while ($lineIndex -lt $removeLines.Count -and $removeLines[$lineIndex]) {
            $lineIndex++
        }
        $endLine = $lineIndex
        $ranges.Add([pscustomobject]@{
            start = [int]$lineStarts[$startLine]
            end = if ($endLine -lt $lineStarts.Count) { [int]$lineStarts[$endLine] } else { $Content.Length }
        })
    }
    if ($ranges.Count -eq 0) {
        return $Content
    }

    # Keep every non-retired byte unchanged; this is a sanitizer, not config normalization.
    $rebuilt = [Text.StringBuilder]::new($Content.Length)
    $cursor = 0
    foreach ($range in $ranges) {
        if ($range.start -lt $cursor -or $range.end -lt $range.start) {
            throw '退役 project trust 的 TOML 删除范围重叠或倒置。'
        }
        if ($range.start -gt $cursor) {
            [void]$rebuilt.Append($Content.Substring($cursor, $range.start - $cursor))
        }
        $cursor = $range.end
    }
    if ($cursor -lt $Content.Length) {
        [void]$rebuilt.Append($Content.Substring($cursor))
    }
    $sanitized = $rebuilt.ToString()
    Assert-ValidToml -Content $sanitized
    return $sanitized
}

function Remove-RetiredProjectTrustFromContent {
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string[]]$RetiredProjectTrusts
    )

    [Collections.Generic.HashSet[string]]$retiredProjectPaths = Get-CanonicalRetiredProjectTrustPaths -RetiredProjectTrusts $RetiredProjectTrusts
    return Remove-RetiredProjectTrustBlocks -Content $Content -RetiredProjectPaths $retiredProjectPaths
}

function Set-DesiredProjectTrust {
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string[]]$TrustedProjects,
        [Parameter(Mandatory)][string[]]$RetiredProjectTrusts
    )

    $document = Get-TomlDocument -Content $Content
    $canonicalTrustedProjects = [Collections.Generic.List[string]]::new()
    $trustedProjectPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($projectPath in $TrustedProjects) {
        $canonicalPath = ConvertTo-CanonicalManagedProjectTrustPath -ProjectPath $projectPath -Role '受管 project trust'
        if (-not $trustedProjectPaths.Add($canonicalPath)) {
            throw "受管 project trust 路径重复：$canonicalPath"
        }
        [void]$canonicalTrustedProjects.Add($canonicalPath)
    }

    [Collections.Generic.HashSet[string]]$retiredProjectPaths = Get-CanonicalRetiredProjectTrustPaths -RetiredProjectTrusts $RetiredProjectTrusts
    foreach ($canonicalPath in $retiredProjectPaths) {
        if ($trustedProjectPaths.Contains($canonicalPath)) {
            throw "退役 project trust 不得与受管 project trust 重叠：$canonicalPath"
        }
    }

    $Content = Remove-RetiredProjectTrustBlocks -Content $Content -RetiredProjectPaths $retiredProjectPaths
    $document = Get-TomlDocument -Content $Content

    $missingProjects = [Collections.Generic.List[string]]::new()
    $missingTrustIndices = [Collections.Generic.HashSet[int]]::new()
    foreach ($canonicalPath in $canonicalTrustedProjects) {
        $segments = @('projects', $canonicalPath.ToLowerInvariant())
        $matchingProjectTrustHeaders = @($document.headers | Where-Object {
            $_.kind -ceq 'table' -and (Test-TomlKeySegmentsEqual -Left @($_.segments) -Right $segments)
        })
        if ($matchingProjectTrustHeaders.Count -gt 1) {
            throw "项目 trust section 重复：$canonicalPath"
        }
        if ($matchingProjectTrustHeaders.Count -eq 0) {
            [void]$missingProjects.Add($canonicalPath.ToLowerInvariant())
            continue
        }

        $header = $matchingProjectTrustHeaders[0]
        $next = @($document.headers | Where-Object { $_.index -gt $header.index } | Sort-Object index | Select-Object -First 1)
        $end = if ($next.Count -eq 1) { $next[0].index } else { $document.lines.Count }
        $trustIndices = @(Get-TomlKeyIndices -Document $document -Key 'trust_level' -Start ($header.index + 1) -End $end)
        if ($trustIndices.Count -gt 1) {
            throw "项目 trust_level 重复：$canonicalPath"
        }
        if ($trustIndices.Count -eq 0) {
            [void]$missingTrustIndices.Add([int]$header.index)
            continue
        }
        Set-TomlKeyLiteral -Document $document -Index $trustIndices[0] -Key 'trust_level' -Literal '"trusted"'
        $Content = [string]::Join($document.newLine, $document.lines)
        $document = Get-TomlDocument -Content $Content
    }
    $rebuilt = [Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $document.lines.Count; $index++) {
        [void]$rebuilt.Add($document.lines[$index])
        if ($missingTrustIndices.Contains($index)) {
            [void]$rebuilt.Add('trust_level = "trusted"')
        }
    }
    $desired = [string]::Join($document.newLine, $rebuilt)
    if ($missingProjects.Count -gt 0) {
        if (-not $desired.EndsWith($document.newLine, [StringComparison]::Ordinal)) {
            $desired += $document.newLine
        }
        foreach ($projectPath in $missingProjects) {
            $desired += $document.newLine + "[projects.'$projectPath']" + $document.newLine + 'trust_level = "trusted"' + $document.newLine
        }
    }
    Assert-ValidToml -Content $desired
    return $desired
}

function Get-DesiredConfig {
    param(
        [string]$Content,
        [string]$ExpectedSerenaContextPath
    )

    $document = Get-TomlDocument -Content $Content
    $firstSectionIndex = if ($document.headers.Count -gt 0) { ($document.headers | Sort-Object index | Select-Object -First 1).index } else { $document.lines.Count }
    $rootFeatureFlags = @{}
    for ($index = 0; $index -lt $firstSectionIndex; $index++) {
        $segments = @(Get-TomlAssignmentKeySegments -Line $document.lines[$index])
        if ($segments.Count -gt 0 -and $segments[0] -ceq "hooks") {
            throw "根级 TOML dotted hook key 不受支持，拒绝写入"
        }
        if ($segments.Count -eq 0 -or $segments[0] -cne 'features') { continue }
        if ($segments.Count -ne 2 -or ($segments[1] -cne 'hooks' -and $segments[1] -cne 'codex_hooks')) {
            throw '根级 features assignment 无法安全解释；拒绝写入'
        }
        $featureKey = [string]$segments[1]
        if ($rootFeatureFlags.ContainsKey($featureKey)) { throw "根级 features boolean key 重复：$featureKey" }
        $equalsIndex = ([string]$document.lines[$index]).IndexOf('=')
        if ($equalsIndex -lt 0) { throw "无法解析根级 features boolean key：$featureKey" }
        $featureValue = [regex]::Match(([string]$document.lines[$index]).Substring($equalsIndex + 1).Trim(), '^(?<value>true|false)\s*(?:#.*)?$')
        if (-not $featureValue.Success) { throw "根级 features boolean key 必须为 true 或 false：$featureKey" }
        $rootFeatureFlags[$featureKey] = [bool]::Parse($featureValue.Groups['value'].Value)
    }
    $rootHooksEnabled = if ($rootFeatureFlags.ContainsKey('hooks')) { [bool]$rootFeatureFlags['hooks'] } else { $null }
    $rootDeprecatedHooksEnabled = if ($rootFeatureFlags.ContainsKey('codex_hooks')) { [bool]$rootFeatureFlags['codex_hooks'] } else { $null }
    if ($rootHooksEnabled -eq $false -or $rootDeprecatedHooksEnabled -eq $false) {
        throw '根级 features.hooks 或已弃用的 features.codex_hooks 被显式关闭；拒绝修改配置'
    }
    if ($null -ne $rootHooksEnabled -and $null -ne $rootDeprecatedHooksEnabled -and $rootHooksEnabled -ne $rootDeprecatedHooksEnabled) {
        throw '根级 features.hooks 与已弃用的 features.codex_hooks 冲突；拒绝修改配置'
    }

    $nestedHookFeatureHeaders = @($document.headers | Where-Object {
        $segments = @($_.segments)
        $segments.Count -ge 2 -and
        $segments[0] -ceq 'features' -and
        ($segments[1] -ceq 'hooks' -or $segments[1] -ceq 'codex_hooks')
    })
    if ($nestedHookFeatureHeaders.Count -gt 0) {
        throw 'features.hooks 或已弃用的 features.codex_hooks 不得作为 TOML table 或 array-table；拒绝修改配置'
    }

    $featureHeaders = @($document.headers | Where-Object {
        Test-TomlKeySegmentsEqual -Left @($_.segments) -Right @('features')
    })
    if ($featureHeaders.Count -gt 1 -or ($featureHeaders.Count -eq 1 -and $featureHeaders[0].kind -cne 'table')) {
        throw 'features TOML section 必须是唯一普通 table'
    }
    if ($featureHeaders.Count -eq 1) {
        $features = Get-UniqueSectionRange -Document $document -Name 'features'
        for ($index = $features.start; $index -lt $features.end; $index++) {
            $segments = @(Get-TomlAssignmentKeySegments -Line $document.lines[$index])
            if ($segments.Count -gt 1 -and ($segments[0] -ceq 'hooks' -or $segments[0] -ceq 'codex_hooks')) {
                throw 'features.hooks 或已弃用的 features.codex_hooks 不得使用 dotted descendant key；拒绝修改配置'
            }
        }
        $hooksEnabled = Get-OptionalTomlBooleanKeyValue -Document $document -Key 'hooks' -Start $features.start -End $features.end -Scope 'features'
        $deprecatedHooksEnabled = Get-OptionalTomlBooleanKeyValue -Document $document -Key 'codex_hooks' -Start $features.start -End $features.end -Scope 'features'
        if ($hooksEnabled -eq $false -or $deprecatedHooksEnabled -eq $false) {
            throw 'features.hooks 或已弃用的 features.codex_hooks 被显式关闭；拒绝修改配置'
        }
        if ($null -ne $hooksEnabled -and $null -ne $deprecatedHooksEnabled -and $hooksEnabled -ne $deprecatedHooksEnabled) {
            throw 'features.hooks 与已弃用的 features.codex_hooks 冲突；拒绝修改配置'
        }
    }

    # 2026-08-31 起 Codex Desktop 26.825 官方把 .cmd 形态的 MCP 条目迁移为
    # cmd.exe /c 包装并附带 --project-from-cwd；canonical 跟随官方形态，
    # 旧直连形态由 Convert-SerenaArgs 接受并收敛。
    $canonicalCommandValue = 'cmd.exe'
    $canonicalCommandLiteral = '"cmd.exe"'
    $canonicalArgs = @("/c", 'D:\Codex\.codex\scripts\start-serena-mcp.cmd', "start-mcp-server", "--context=$ExpectedSerenaContextPath", "--project-from-cwd", "--enable-web-dashboard=true", "--open-web-dashboard=false")
    $canonicalArgsLiteral = ConvertTo-Json -InputObject $canonicalArgs -Compress
    $serena = Get-UniqueSectionRange -Document $document -Name "mcp_servers.serena" -AllowMissing
    if ($null -eq $serena) {
        $serenaSegments = @("mcp_servers", "serena")
        $insertAt = $document.lines.Count
        foreach ($header in @($document.headers | Sort-Object index)) {
            if (@($header.segments).Count -le $serenaSegments.Count) {
                continue
            }

            $isSerenaDescendant = $true
            for ($segmentIndex = 0; $segmentIndex -lt $serenaSegments.Count; $segmentIndex++) {
                if ([string]$header.segments[$segmentIndex] -cne $serenaSegments[$segmentIndex]) {
                    $isSerenaDescendant = $false
                    break
                }
            }
            if ($isSerenaDescendant) {
                $insertAt = [int]$header.index
                break
            }
        }

        $insertLines = @(
            "[mcp_servers.serena]",
            "command = $canonicalCommandLiteral",
            "args = $canonicalArgsLiteral"
        )
        $rebuilt = [System.Collections.Generic.List[string]]::new()
        for ($index = 0; $index -lt $document.lines.Count; $index++) {
            if ($index -eq $insertAt) {
                foreach ($line in $insertLines) { [void]$rebuilt.Add($line) }
            }
            [void]$rebuilt.Add($document.lines[$index])
        }
        if ($insertAt -eq $document.lines.Count) {
            foreach ($line in $insertLines) { [void]$rebuilt.Add($line) }
        }
        $insertedContent = [string]::Join($document.newLine, $rebuilt)
        if ($insertedContent.Equals($Content, [System.StringComparison]::Ordinal)) {
            throw "Serena section 缺失插入未取得进展"
        }
        Assert-ValidToml -Content $insertedContent
        $normalizedAfterInsert = Get-DesiredConfig -Content $insertedContent -ExpectedSerenaContextPath $ExpectedSerenaContextPath
        return [pscustomobject]@{
            content = [string]$normalizedAfterInsert.content
            changed = -not $Content.Equals([string]$normalizedAfterInsert.content, [System.StringComparison]::Ordinal)
        }
    }

    $commandIndices = @(Get-TomlKeyIndices -Document $document -Key "command" -Start $serena.start -End $serena.end)
    $argsIndices = @(Get-TomlKeyIndices -Document $document -Key "args" -Start $serena.start -End $serena.end)
    if ($commandIndices.Count -gt 1) { throw "Serena command 最多出现一次；实际 $($commandIndices.Count)" }
    if ($argsIndices.Count -gt 1) { throw "Serena args 最多出现一次；实际 $($argsIndices.Count)" }
    if ($commandIndices.Count -eq 0 -or $argsIndices.Count -eq 0) {
        $insertLines = [System.Collections.Generic.List[string]]::new()
        if ($commandIndices.Count -eq 0) { [void]$insertLines.Add("command = $canonicalCommandLiteral") }
        if ($argsIndices.Count -eq 0) { [void]$insertLines.Add("args = $canonicalArgsLiteral") }
        $rebuilt = [System.Collections.Generic.List[string]]::new()
        for ($index = 0; $index -lt $document.lines.Count; $index++) {
            if ($index -eq $serena.start) { foreach ($line in $insertLines) { [void]$rebuilt.Add($line) } }
            [void]$rebuilt.Add($document.lines[$index])
        }
        if ($serena.start -eq $document.lines.Count) {
            foreach ($line in $insertLines) { [void]$rebuilt.Add($line) }
        }
        $insertedContent = [string]::Join($document.newLine, $rebuilt)
        if ($insertedContent.Equals($Content, [System.StringComparison]::Ordinal)) {
            throw "Serena command/args 缺失插入未取得进展"
        }
        Assert-ValidToml -Content $insertedContent
        $normalizedAfterInsert = Get-DesiredConfig -Content $insertedContent -ExpectedSerenaContextPath $ExpectedSerenaContextPath
        return [pscustomobject]@{
            content = [string]$normalizedAfterInsert.content
            changed = -not $Content.Equals([string]$normalizedAfterInsert.content, [System.StringComparison]::Ordinal)
        }
    }

    $commandIndex = $commandIndices[0]
    $commandLine = [string]$document.lines[$commandIndex]
    $commandEqualsIndex = $commandLine.IndexOf('=')
    if ($commandEqualsIndex -lt 0) {
        throw "无法解析 Serena command"
    }
    $commandAlreadyDesired = $false
    try {
        $commandValue = ConvertFrom-SingleLineTomlString -Literal $commandLine.Substring($commandEqualsIndex + 1).Trim()
        $commandAlreadyDesired = $commandValue -ceq $canonicalCommandValue
    } catch {
        # Keep the existing repair behavior for values outside the narrow safe parser.
        $commandAlreadyDesired = $false
    }
    if (-not $commandAlreadyDesired) {
        Set-TomlKeyLiteral -Document $document -Index $commandIndex -Key "command" -Literal $canonicalCommandLiteral
    }

    $argsIndex = $argsIndices[0]
    $argsLine = $document.lines[$argsIndex]
    $equalsIndex = $argsLine.IndexOf('=')
    if ($equalsIndex -lt 0) {
        throw "无法解析 Serena args"
    }
    $argsRightHandSide = $argsLine.Substring($equalsIndex + 1).Trim()
    $argsLiteral = Convert-SerenaArgs -RightHandSide $argsRightHandSide -ExpectedContextPath $ExpectedSerenaContextPath
    $actualArgs = @(ConvertFrom-SingleLineTomlStringArray -Literal $argsRightHandSide)
    $normalizedArgs = @((ConvertFrom-Json -InputObject $argsLiteral -NoEnumerate))
    $argsAlreadyDesired = $actualArgs.Count -eq $normalizedArgs.Count
    if ($argsAlreadyDesired) {
        for ($argsIndexValue = 0; $argsIndexValue -lt $normalizedArgs.Count; $argsIndexValue++) {
            if ([string]$actualArgs[$argsIndexValue] -cne [string]$normalizedArgs[$argsIndexValue]) {
                $argsAlreadyDesired = $false
                break
            }
        }
    }
    if (-not $argsAlreadyDesired) {
        Set-TomlKeyLiteral -Document $document -Index $argsIndex -Key "args" -Literal $argsLiteral
    }

    $keep = [bool[]]::new($document.lines.Count)
    [array]::Fill($keep, $true)
    $headers = @($document.headers | Sort-Object index)
    for ($headerIndex = 0; $headerIndex -lt $headers.Count; $headerIndex++) {
        $header = $headers[$headerIndex]
        if (@($header.segments).Count -lt 2 -or $header.segments[0] -cne 'hooks' -or $header.segments[1] -cne 'state') {
            continue
        }
        $end = if ($headerIndex + 1 -lt $headers.Count) { $headers[$headerIndex + 1].index } else { $document.lines.Count }
        for ($lineIndex = $header.index; $lineIndex -lt $end; $lineIndex++) {
            $keep[$lineIndex] = $false
        }
    }
    for ($headerIndex = 0; $headerIndex -lt $headers.Count; $headerIndex++) {
        $header = $headers[$headerIndex]
        if ($header.kind -cne 'table' -or -not (Test-TomlKeySegmentsEqual -Left @($header.segments) -Right @('hooks'))) {
            continue
        }
        $end = if ($headerIndex + 1 -lt $headers.Count) { $headers[$headerIndex + 1].index } else { $document.lines.Count }
        $hasUserContent = $false
        for ($lineIndex = $header.index + 1; $lineIndex -lt $end; $lineIndex++) {
            if ($keep[$lineIndex] -and -not [string]::IsNullOrWhiteSpace([string]$document.lines[$lineIndex])) {
                $hasUserContent = $true
                break
            }
        }
        if (-not $hasUserContent) { $keep[$header.index] = $false }
    }

    $keptLines = [System.Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $document.lines.Count; $index++) {
        if ($keep[$index]) {
            $keptLines.Add($document.lines[$index])
        }
    }
    $desired = [string]::Join($document.newLine, $keptLines)
    $desired = Set-DesiredProjectTrust -Content $desired -TrustedProjects @($script:HostPreflightManifest.trustedProjects) -RetiredProjectTrusts @($script:HostPreflightManifest.retiredProjectTrusts)
    Assert-ValidToml -Content $desired

    [pscustomobject]@{
        content = $desired
        changed = -not $Content.Equals($desired, [System.StringComparison]::Ordinal)
    }
}

function Remove-KnownRetiredHookRegistrations {
    param([object]$Registry)

    $result = Copy-CodexHookJsonValue -Value $Registry
    $retiredManifest = Get-CodexHookKnownRetiredRegistrationManifest
    foreach ($eventProperty in @($result.hooks.PSObject.Properties)) {
        $eventName = [string]$eventProperty.Name
        $keptGroups = [System.Collections.Generic.List[object]]::new()
        foreach ($group in @($eventProperty.Value)) {
            if ($null -eq $group -or $group.PSObject.Properties.Name -notcontains 'hooks') { $keptGroups.Add($group); continue }
            $matcher = if ($group.PSObject.Properties.Name -contains 'matcher') { $group.matcher } else { $null }
            $keptEntries = [System.Collections.Generic.List[object]]::new()
            foreach ($entry in @($group.hooks)) {
                $isRetired = $false
                if ($null -ne $entry -and $entry.PSObject.Properties.Name -contains 'type' -and $entry.type -ceq 'command' -and $entry.command -is [string]) {
                    $parsed = Split-CodexHookCommandLine -Command ([string]$entry.command)
                    if ($parsed.parsed) {
                        $retiredManifestMatches = @(Get-CodexHookManifestMatches -Manifest $retiredManifest -Event $eventName -Matcher $matcher -Tokens $parsed.tokens -IsCommandEntry $true | Where-Object { $null -ne $_ })
                        $isRetired = $retiredManifestMatches.Count -eq 1
                    }
                }
                if (-not $isRetired) { $keptEntries.Add($entry) }
            }
            if ($keptEntries.Count -gt 0) {
                $group.hooks = $keptEntries.ToArray()
                $keptGroups.Add($group)
            }
        }
        if ($keptGroups.Count -eq 0) { $result.hooks.PSObject.Properties.Remove($eventName) } else { $result.hooks.$eventName = $keptGroups.ToArray() }
    }
    $result
}

function Get-DesiredHooksJson {
    param([string]$Content)

    try {
        $document = [System.Text.Json.JsonDocument]::Parse($Content)
    } catch {
        throw "hooks.json 无法解析：$($_.Exception.Message)"
    }

    $desired = $null
    try {
        if ($document.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
            throw "hooks.json 顶层必须是 JSON 对象"
        }
        $properties = @($document.RootElement.EnumerateObject())
        $propertyNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($property in $properties) {
            if (-not $propertyNames.Add($property.Name)) {
                throw "hooks.json 顶层属性不得重复：$($property.Name)"
            }
        }
        $hookProperties = @($properties | Where-Object { $_.Name -ceq "hooks" })
        if ($hookProperties.Count -ne 1) {
            throw "hooks.json 必须恰好包含一个 hooks 属性"
        }
        if ($hookProperties[0].Value.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
            throw "hooks.json 的 hooks 必须是 JSON 对象"
        }
        $liveRegistry = Remove-KnownRetiredHookRegistrations -Registry ($Content | ConvertFrom-Json)
        $mergedRegistry = Merge-CodexHookRegistry -Manifest $script:HostPreflightManifest -LiveRegistry $liveRegistry -Mode full
        $mergedHooksJson = ($mergedRegistry.hooks | ConvertTo-Json -Depth 40 -Compress)
        $currentHooksJson = (($hookProperties[0].Value.GetRawText() | ConvertFrom-Json) | ConvertTo-Json -Depth 40 -Compress)
        $alreadyDesired = $currentHooksJson -ceq $mergedHooksJson
        if (-not $alreadyDesired) {
            $stream = [System.IO.MemoryStream]::new()
            $options = [System.Text.Json.JsonWriterOptions]::new()
            $options.Indented = $true
            $writer = [System.Text.Json.Utf8JsonWriter]::new($stream, $options)
            try {
                $writer.WriteStartObject()
                foreach ($property in $properties) {
                    $writer.WritePropertyName($property.Name)
                    if ($property.Name -ceq "hooks") {
                        $writer.WriteRawValue($mergedHooksJson, $true)
                    } else {
                        $writer.WriteRawValue($property.Value.GetRawText(), $true)
                    }
                }
                $writer.WriteEndObject()
                $writer.Flush()
                $desired = [System.Text.UTF8Encoding]::new($false).GetString($stream.ToArray()) + "`n"
            } finally {
                $writer.Dispose()
                $stream.Dispose()
            }
        }
    } finally {
        $document.Dispose()
    }

    if ($alreadyDesired) {
        return [pscustomobject]@{
            content = $Content
            changed = $false
        }
    }

    [pscustomobject]@{
        content = $desired
        changed = -not $Content.Equals($desired, [System.StringComparison]::Ordinal)
    }
}

function Get-AllowedWriterSids {
    @(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value,
        "S-1-5-18",
        "S-1-5-32-544"
    )
}

function Test-ProtectedAcl {
    param([string]$Path)

    $allowed = @(Get-AllowedWriterSids)
    $acl = Get-Acl -LiteralPath $Path
    $ownerSid = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    $ownerAllowed = $allowed -contains $ownerSid
    $writeMask = [System.Security.AccessControl.FileSystemRights]::WriteData -bor
        [System.Security.AccessControl.FileSystemRights]::CreateFiles -bor
        [System.Security.AccessControl.FileSystemRights]::AppendData -bor
        [System.Security.AccessControl.FileSystemRights]::CreateDirectories -bor
        [System.Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
        [System.Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [System.Security.AccessControl.FileSystemRights]::Delete -bor
        [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [System.Security.AccessControl.FileSystemRights]::TakeOwnership
    $writers = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $unexpected = [System.Collections.Generic.List[string]]::new()
    $missingInheritance = [System.Collections.Generic.List[string]]::new()
    $denyCount = 0
    $isDirectory = (Get-Item -LiteralPath $Path -Force).PSIsContainer
    foreach ($rule in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Deny) {
            $denyCount++
            continue
        }
        if (($rule.FileSystemRights -band $writeMask) -eq 0) {
            continue
        }
        $sid = $rule.IdentityReference.Value
        $writers.Add($sid) | Out-Null
        if ($allowed -notcontains $sid) {
            $unexpected.Add($sid)
        } elseif ($isDirectory) {
            $requiredInheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
            if (($rule.InheritanceFlags -band $requiredInheritance) -ne $requiredInheritance) {
                $missingInheritance.Add($sid)
            }
        }
    }
    $missing = @($allowed | Where-Object { -not $writers.Contains($_) })

    [pscustomobject]@{
        ok = $ownerAllowed -and $acl.AreAccessRulesProtected -and $unexpected.Count -eq 0 -and $missing.Count -eq 0 -and $missingInheritance.Count -eq 0 -and $denyCount -eq 0
        ownerAllowed = $ownerAllowed
        protected = $acl.AreAccessRulesProtected
        unexpectedWriterCount = $unexpected.Count
        missingRequiredWriterCount = $missing.Count
        missingInheritanceCount = $missingInheritance.Count
        denyRuleCount = $denyCount
    }
}

function Set-ProtectedAclCurrentUserOwner {
    param([string]$Path)

    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = Get-Acl -LiteralPath $Path
    $owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier])
    if ($null -eq $owner -or $owner.Value -ne $currentSid.Value) {
        $acl.SetOwner($currentSid)
        Set-Acl -LiteralPath $Path -AclObject $acl
    }
}

function Set-AclOwnerAndGroupFromSddl {
    param(
        [string]$Path,
        [string]$Sddl
    )

    if ([string]::IsNullOrWhiteSpace($Sddl)) { return }
    $probe = [System.Security.AccessControl.FileSecurity]::new()
    $sections = [Security.AccessControl.AccessControlSections]::Owner -bor [Security.AccessControl.AccessControlSections]::Group
    $probe.SetSecurityDescriptorSddlForm($Sddl, $sections)
    $desiredOwner = $probe.GetOwner([System.Security.Principal.SecurityIdentifier])
    $desiredGroup = $probe.GetGroup([System.Security.Principal.SecurityIdentifier])
    $acl = Get-Acl -LiteralPath $Path
    $changed = $false
    $currentOwner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier])
    $currentGroup = $acl.GetGroup([System.Security.Principal.SecurityIdentifier])
    if ($null -ne $desiredOwner -and ($null -eq $currentOwner -or $currentOwner.Value -ne $desiredOwner.Value)) {
        $acl.SetOwner($desiredOwner)
        $changed = $true
    }
    if ($null -ne $desiredGroup -and ($null -eq $currentGroup -or $currentGroup.Value -ne $desiredGroup.Value)) {
        $acl.SetGroup($desiredGroup)
        $changed = $true
    }
    if ($changed) {
        Set-Acl -LiteralPath $Path -AclObject $acl
    }
}

function Get-ProtectedAclSddl {
    param(
        [string]$CurrentSddl,
        [bool]$IsDirectory
    )

    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $security = if ($IsDirectory) {
        [System.Security.AccessControl.DirectorySecurity]::new()
    } else {
        [System.Security.AccessControl.FileSecurity]::new()
    }
    $sections = [Security.AccessControl.AccessControlSections]::Owner -bor [Security.AccessControl.AccessControlSections]::Group -bor [Security.AccessControl.AccessControlSections]::Access
    $security.SetSecurityDescriptorSddlForm($CurrentSddl, $sections)
    $existingAcl = if ($IsDirectory) {
        [System.Security.AccessControl.DirectorySecurity]::new()
    } else {
        [System.Security.AccessControl.FileSecurity]::new()
    }
    $existingAcl.SetSecurityDescriptorSddlForm($CurrentSddl, $sections)
    $security.SetOwner($currentSid)
    $security.SetAccessRuleProtection($true, $false)

    $allowed = @(Get-AllowedWriterSids)
    $readMask = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute -bor
        [System.Security.AccessControl.FileSystemRights]::Read -bor
        [System.Security.AccessControl.FileSystemRights]::Synchronize
    foreach ($existingRule in $existingAcl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
        $sidValue = $existingRule.IdentityReference.Value
        if ($existingRule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow -or $allowed -contains $sidValue) {
            continue
        }
        $readRights = $existingRule.FileSystemRights -band $readMask
        if ($readRights -eq 0) {
            continue
        }
        $readRule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            [System.Security.Principal.SecurityIdentifier]::new($sidValue),
            $readRights,
            $existingRule.InheritanceFlags,
            $existingRule.PropagationFlags,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $security.AddAccessRule($readRule) | Out-Null
    }

    foreach ($sidValue in $allowed) {
        $sid = [System.Security.Principal.SecurityIdentifier]::new($sidValue)
        if ($IsDirectory) {
            $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
                $sid,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit,
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow
            )
        } else {
            $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
                $sid,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                [System.Security.AccessControl.AccessControlType]::Allow
            )
        }
        $security.AddAccessRule($rule) | Out-Null
    }

    [string]$security.Sddl
}

function Set-ProtectedAcl {
    param([string]$Path)

    if ($null -ne $script:FixtureForbiddenAclPath -and $Path.Equals($script:FixtureForbiddenAclPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "fixture-only retired path ACL mutation forbidden"
    }

    if ((Test-ProtectedAcl -Path $Path).ok) { return }
    $item = Get-Item -LiteralPath $Path -Force
    $currentSddl = (Get-Acl -LiteralPath $Path).Sddl
    $desiredSddl = Get-ProtectedAclSddl -CurrentSddl $currentSddl -IsDirectory ([bool]$item.PSIsContainer)
    $security = if ($item.PSIsContainer) { [Security.AccessControl.DirectorySecurity]::new() } else { [Security.AccessControl.FileSecurity]::new() }
    $sections = [Security.AccessControl.AccessControlSections]::Owner -bor [Security.AccessControl.AccessControlSections]::Group -bor [Security.AccessControl.AccessControlSections]::Access
    $security.SetSecurityDescriptorSddlForm($desiredSddl, $sections)
    Set-Acl -LiteralPath $Path -AclObject $security
}

function Set-ProtectedAclWithCapability {
    param(
        [string]$Path,
        [string]$CapabilityRoot
    )

    $fullPath = Assert-CodexHookCapabilityPath -Path $Path -CapabilityRoot $CapabilityRoot -AllowedExactPaths @($Path) -Name 'protected ACL target'
    $targetGuard = if (Test-Path -LiteralPath $fullPath -PathType Container) { [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire($CapabilityRoot, $fullPath, $false) } else { $null }
    $parentGuard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire($CapabilityRoot, [IO.Path]::GetDirectoryName($fullPath), $false)
    $lease = $null
    try {
        Set-ProtectedAclCurrentUserOwner -Path $fullPath
        $lease = $parentGuard.AcquireAclTargetLease($fullPath)
        $currentSddl = [string]$lease.GetSecurityDescriptorSddl()
        $desiredSddl = Get-ProtectedAclSddl -CurrentSddl $currentSddl -IsDirectory ([bool]$lease.IsDirectory)
        if ($currentSddl -cne $desiredSddl) { $lease.SetSecurityDescriptorSddl($currentSddl, $desiredSddl) }
        if ([string]$lease.GetSecurityDescriptorSddl() -cne $desiredSddl) { throw 'protected ACL same-handle postcheck 失败' }
    } finally {
        if ($null -ne $lease) { $lease.Dispose() }
        $parentGuard.Dispose()
        if ($null -ne $targetGuard) { $targetGuard.Dispose() }
    }
}

function Get-DesiredSerenaContext {
    param([string]$Content)

    if ($Content.Contains("`t", [System.StringComparison]::Ordinal)) { throw "Serena context 不允许 tab" }
    if ($Content -match "`r(?!`n)") { throw "Serena context 不允许非 CRLF 的裸 CR" }
    $lineMatches = @([regex]::Matches($Content, '(?m)^(?<text>[^\r\n]*)(?<eol>\r\n|\n|\r|$)') | Where-Object { $_.Length -gt 0 })
    if ($lineMatches.Count -eq 0) { throw "Serena context 不能为空" }
    $coveredOffset = 0
    foreach ($lineMatch in $lineMatches) {
        if ($lineMatch.Index -ne $coveredOffset) { throw "Serena context 行扫描存在未覆盖字符" }
        $coveredOffset += $lineMatch.Length
    }
    if ($coveredOffset -ne $Content.Length) { throw "Serena context 行扫描未覆盖输入全长" }
    $keys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $promptHeaderIndex = -1
    $collectionKey = $null
    $collectionItemCount = 0
    $inPrompt = $false
    for ($index = 0; $index -lt $lineMatches.Count; $index++) {
        $line = $lineMatches[$index].Groups['text'].Value
        if ($inPrompt) {
            if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("  ", [System.StringComparison]::Ordinal)) { continue }
            $inPrompt = $false
        }
        if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^\s*#') { continue }
        if ($line -match '^(?:%|---\s*$|\.\.\.\s*$)' -or $line -match '(^|\s)(?:&|\*|!|<<:)') {
            throw "Serena context 包含不受支持的 YAML directive、document marker、anchor、alias 或 tag"
        }
        if ($line.StartsWith("  - ", [System.StringComparison]::Ordinal)) {
            if ($null -eq $collectionKey) { throw "Serena context 顶层外出现孤立 list item" }
            $item = $line.Substring(4).Trim()
            if ($item -notmatch '^[A-Za-z0-9_.-]+$') { throw "Serena context list 只允许无引号 allowlist scalar" }
            $collectionItemCount++
            continue
        }
        if ($line.StartsWith(" ", [System.StringComparison]::Ordinal)) { throw "Serena context 包含未知或错误缩进" }
        if ($null -ne $collectionKey -and $collectionItemCount -eq 0) { throw "Serena context 空 value 必须至少包含一个 list item：$collectionKey" }
        $collectionKey = $null
        $collectionItemCount = 0
        $match = [regex]::Match($line, '^(?<key>[A-Za-z_][A-Za-z0-9_-]*)\s*:\s*(?<value>.*)$')
        if (-not $match.Success) { throw "Serena context 只允许顶层唯一 mapping" }
        $key = $match.Groups['key'].Value
        if (-not $keys.Add($key)) { throw "Serena context 顶层 key 重复：$key" }
        $value = $match.Groups['value'].Value
        if ($key -ceq 'prompt') {
            if ($value -notmatch '^\|\s*(?:#.*)?$') { throw "Serena prompt 必须是 literal block" }
            $promptHeaderIndex = $index
            $inPrompt = $true
            continue
        }
        if ([string]::IsNullOrWhiteSpace($value)) { $collectionKey = $key; $collectionItemCount = 0; continue }
        if ($value.Trim() -ceq '{}') { continue }
        if ($value -notmatch '^[A-Za-z0-9_./ -]+$') { throw "Serena context scalar 必须属于无引号 allowlist 子集" }
    }
    if ($null -ne $collectionKey -and $collectionItemCount -eq 0) { throw "Serena context 空 value 必须至少包含一个 list item：$collectionKey" }
    if ($promptHeaderIndex -lt 0) { throw "Serena context 缺少唯一根级 prompt literal block" }

    $promptEndIndex = $lineMatches.Count
    $promptLogicalLines = [System.Collections.Generic.List[string]]::new()
    for ($index = $promptHeaderIndex + 1; $index -lt $lineMatches.Count; $index++) {
        $line = $lineMatches[$index].Groups['text'].Value
        if (-not [string]::IsNullOrWhiteSpace($line) -and -not $line.StartsWith("  ", [System.StringComparison]::Ordinal)) { $promptEndIndex = $index; break }
        if ($line.StartsWith("  ", [System.StringComparison]::Ordinal)) { $promptLogicalLines.Add($line.Substring(2)) } else { $promptLogicalLines.Add("") }
    }
    $marker = '[codex-serena-activation-policy:v1 mandatory]'
    $globalMarkerCount = [regex]::Matches($Content, [regex]::Escape($marker)).Count
    $promptMarkerCount = [regex]::Matches(($promptLogicalLines -join "`n"), [regex]::Escape($marker)).Count
    if ($globalMarkerCount -gt 1) { throw "Serena context canonical mandatory marker 重复" }
    if ($globalMarkerCount -ne $promptMarkerCount) { throw "Serena context canonical mandatory marker 不得出现在 prompt 外" }
    $canonicalLogicalLines = @(
        $marker,
        "Codex owns shell execution; Serena provides project-scoped semantic tools.",
        "Before using any project-scoped Serena tool in a repository task, explicitly",
        "call activate_project with the absolute current workspace or repository root",
        "from Codex's environment_context, then verify the result with",
        "get_current_config. Never infer the task project from Serena's initial active",
        "project or from the Serena process working directory."
    )
    if (($promptLogicalLines -join "`n") -ceq ($canonicalLogicalLines -join "`n")) {
        return [pscustomobject]@{ content = $Content; changed = $false }
    }

    $promptBodyStartOffset = $lineMatches[$promptHeaderIndex].Index + $lineMatches[$promptHeaderIndex].Length
    $promptEndOffset = if ($promptEndIndex -lt $lineMatches.Count) { $lineMatches[$promptEndIndex].Index } else { $Content.Length }
    $newLine = $lineMatches[$promptHeaderIndex].Groups['eol'].Value
    if ([string]::IsNullOrEmpty($newLine)) { $newLine = "`n" }
    $replacement = (@($canonicalLogicalLines | ForEach-Object { "  $_" }) -join $newLine)
    $promptBodyHadTrailingNewLine = $promptEndOffset -gt $promptBodyStartOffset -and $Content[$promptEndOffset - 1] -in @("`n", "`r")
    if ($promptBodyHadTrailingNewLine -or $promptEndOffset -lt $Content.Length) { $replacement += $newLine }
    $desired = $Content.Remove($promptBodyStartOffset, $promptEndOffset - $promptBodyStartOffset).Insert($promptBodyStartOffset, $replacement)
    [pscustomobject]@{ content = $desired; changed = $true }
}

function Get-ReconciliationState {
    param([string]$ResolvedCodexHome)

    $configPath = Join-Path $ResolvedCodexHome "config.toml"
    $hooksPath = Join-Path $ResolvedCodexHome "hooks.json"
    $hookDirectory = Join-Path $ResolvedCodexHome "hooks"
    $hostRoot = [System.IO.Directory]::GetParent($ResolvedCodexHome).FullName
    $serenaContextDirectory = Join-Path $hostRoot ".serena\contexts"
    $serenaContextPath = Join-Path $serenaContextDirectory "codex-file-tools.yml"
    foreach ($path in @($configPath, $hooksPath, $hookDirectory, $serenaContextDirectory, $serenaContextPath)) {
        Assert-NoReparsePath -Path $path -RequireLeaf | Out-Null
    }
    $configContent = Read-Text -Path $configPath
    $hooksContent = Read-Text -Path $hooksPath
    $serenaContextContent = Read-Text -Path $serenaContextPath
    $desiredSerenaContext = Get-DesiredSerenaContext -Content $serenaContextContent
    $desiredConfig = Get-DesiredConfig -Content $configContent -ExpectedSerenaContextPath $serenaContextPath
    $desiredHooks = Get-DesiredHooksJson -Content $hooksContent
    $managedFileStates = @(Get-ManagedHookFileStates -ResolvedCodexHome $ResolvedCodexHome)
    $runtimeDependencyStates = @(Get-HostRuntimeDependencyStates -ResolvedCodexHome $ResolvedCodexHome)
    $environmentState = Get-SerenaEnvironmentState -ResolvedCodexHome $ResolvedCodexHome
    $legacyPresent = @($script:LegacyHookNames | Where-Object {
        $candidate = Join-Path $hookDirectory $_
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return $false
        }
        Assert-NoReparsePath -Path $candidate -RequireLeaf | Out-Null
        $true
    })
    $legacyDirectoriesPresent = @($script:LegacyHookDirectoryNames | Where-Object {
        $candidate = Join-Path $hookDirectory $_
        if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
            return $false
        }
        Assert-NoReparsePath -Path $candidate -RequireLeaf | Out-Null
        $true
    })
    $hookTree = @(Get-Item -LiteralPath $hookDirectory -Force) + @(Get-ChildItem -LiteralPath $hookDirectory -Recurse -Force)
    foreach ($item in $hookTree) {
        Assert-NoReparsePath -Path $item.FullName -RequireLeaf | Out-Null
    }
    $preservedHookTree = @(Get-PreservedHookTreeInventory -HookDirectory $hookDirectory -HookTree $hookTree)
    # config.toml is a vendor-owned volatile artifact: Codex Desktop may replace
    # the file atomically, so its leaf ACL is not a durable policy boundary.
    # Keep its contents under semantic reconciliation, and reserve ACL health
    # for the stable hook and Serena surfaces owned by this reconciler.
    $aclStates = @(
        Test-ProtectedAcl -Path $hooksPath
        Test-ProtectedAcl -Path $serenaContextPath
        $hookTree | ForEach-Object { Test-ProtectedAcl -Path $_.FullName }
    )

    $checks = @(
        [pscustomobject]@{ name = "serenaContext"; ok = -not $desiredSerenaContext.changed },
        [pscustomobject]@{ name = "config"; ok = -not $desiredConfig.changed },
        [pscustomobject]@{ name = "registrations"; ok = -not $desiredHooks.changed },
        [pscustomobject]@{ name = "managedFiles"; ok = @($managedFileStates | Where-Object { -not $_.ok }).Count -eq 0; driftedTargetCount = @($managedFileStates | Where-Object { -not $_.ok }).Count },
        [pscustomobject]@{ name = "runtimeDependencies"; ok = @($runtimeDependencyStates | Where-Object { -not $_.ok }).Count -eq 0; unavailableRuntimeIds = @($runtimeDependencyStates | Where-Object { -not $_.ok } | ForEach-Object { [string]$_.id }) },
        [pscustomobject]@{ name = "environment"; ok = [bool]$environmentState.ok },
        [pscustomobject]@{ name = "legacyImplementations"; ok = $legacyPresent.Count -eq 0 -and $legacyDirectoriesPresent.Count -eq 0; presentCount = $legacyPresent.Count + $legacyDirectoriesPresent.Count },
        [pscustomobject]@{ name = "acl"; ok = @($aclStates | Where-Object { -not $_.ok }).Count -eq 0; driftedTargetCount = @($aclStates | Where-Object { -not $_.ok }).Count }
    )
    $driftCount = @($checks | Where-Object { -not $_.ok }).Count

    [pscustomobject]@{
        configPath = $configPath
        hooksPath = $hooksPath
        hookDirectory = $hookDirectory
        serenaContextDirectory = $serenaContextDirectory
        serenaContextPath = $serenaContextPath
        serenaContextContent = $serenaContextContent
        desiredSerenaContext = $desiredSerenaContext
        hookTreePaths = @($hookTree | ForEach-Object { $_.FullName })
        preservedHookTree = $preservedHookTree
        configContent = $configContent
        hooksContent = $hooksContent
        desiredConfig = $desiredConfig
        desiredHooks = $desiredHooks
        managedFileStates = $managedFileStates
        runtimeDependencyStates = $runtimeDependencyStates
        environmentState = $environmentState
        legacyPresent = $legacyPresent
        legacyDirectoriesPresent = $legacyDirectoriesPresent
        checks = $checks
        driftCount = $driftCount
        ok = $driftCount -eq 0
    }
}

function New-Result {
    param(
        [string]$ResultMode,
        [object]$State,
        [bool]$Changed,
        [AllowNull()][object]$EvidencePath
    )

    $requiresActivation = $Changed -or [bool]$State.desiredHooks.changed
    $registrationProjection = foreach ($hook in @($script:HostPreflightManifest.hooks)) {
        $ownedFiles = @($script:HostPreflightManifest.files | Where-Object { @($_.ownerHookIds) -ccontains [string]$hook.id })
        $wrapperLeaf = [IO.Path]::GetFileName([string]$hook.wrapperPath)
        $implementationLeaf = [IO.Path]::GetFileName([string]$hook.implementationPath)
        $wrapperFile = @($ownedFiles | Where-Object { [string]$_.liveRelativePath -ceq $wrapperLeaf })
        $implementationFile = @($ownedFiles | Where-Object { [string]$_.liveRelativePath -ceq $implementationLeaf })
        if ($wrapperFile.Count -ne 1 -or $implementationFile.Count -ne 1) {
            throw "registration projection 文件闭包非法：$($hook.id)"
        }
        $sourceClosure = @($ownedFiles | Sort-Object -Property relativePath | ForEach-Object {
            ([string]$_.relativePath) + '=' + ([string]$_.sha256).ToLowerInvariant()
        }) -join "`n"
        $runtimeState = @($State.runtimeDependencyStates | Where-Object { [string]$_.id -ceq [string]$hook.runtimeId })
        if ($runtimeState.Count -ne 1) { throw "registration projection runtime closure 非法：$($hook.id)" }
        $launcherImplementationSha256 = $null
        $launcherRuntimeSha256 = $null
        if (-not [string]::IsNullOrEmpty([string]$hook.launcherRuntimeId)) {
            $launcherRuntimeState = @($State.runtimeDependencyStates | Where-Object { [string]$_.id -ceq [string]$hook.launcherRuntimeId })
            if ($launcherRuntimeState.Count -ne 1) { throw "registration projection launcher runtime closure 非法：$($hook.id)" }
            $launcherRuntimeSha256 = $launcherRuntimeState[0].sha256
            $launcherRelativePath = [IO.Path]::GetRelativePath(
                [IO.Path]::GetFullPath('D:\Codex\.codex\hooks'),
                [IO.Path]::GetFullPath([string]$hook.launcherImplementationPath)
            ).Replace('\', '/')
            $launcherImplementationFile = @($ownedFiles | Where-Object { [string]$_.liveRelativePath -ceq $launcherRelativePath })
            if ($launcherImplementationFile.Count -ne 1) { throw "registration projection launcher implementation closure 非法：$($hook.id)" }
            $launcherImplementationSha256 = ([string]$launcherImplementationFile[0].sha256).ToLowerInvariant()
        }
        [pscustomobject][ordered]@{
            identity = (Get-TextSha256 -Content (Get-CodexHookCommandIdentity -Hook $hook)).ToLowerInvariant()
            id = [string]$hook.id
            event = [string]$hook.event
            order = [int]$hook.order
            matcher = $hook.matcher
            timeoutSeconds = [int]$hook.timeoutSeconds
            sourceSha256 = (Get-TextSha256 -Content $sourceClosure).ToLowerInvariant()
            wrapperSha256 = ([string]$wrapperFile[0].sha256).ToLowerInvariant()
            implementationSha256 = ([string]$implementationFile[0].sha256).ToLowerInvariant()
            runtimeSha256 = $runtimeState[0].sha256
            launcherImplementationSha256 = $launcherImplementationSha256
            launcherRuntimeSha256 = $launcherRuntimeSha256
            trustRequired = [bool]$requiresActivation
            restartRequired = [bool]$requiresActivation
        }
    }

    [pscustomobject]@{
        schemaVersion = 1
        mode = $ResultMode
        ok = [bool]$State.ok
        changed = $Changed
        driftCount = [int]$State.driftCount
        checks = @($State.checks)
        registrationProjection = @($registrationProjection)
        evidencePath = $EvidencePath
    }
}

function Write-Manifest {
    param(
        [string]$Path,
        [System.Collections.IDictionary]$Manifest
    )

    $content = (ConvertTo-Json -InputObject $Manifest -Depth 12) + "`n"
    [byte[]]$bytes = [Text.UTF8Encoding]::new($false).GetBytes($content)
    $capabilityRoot = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    $snapshot = Get-CodexHookCapabilityFileSnapshot -Path $Path -CapabilityRoot $capabilityRoot -AllowedExactPaths @($Path) -Name 'evidence manifest'
    if (-not $snapshot.exists) {
        [void](Write-NewOnlyProtectedBytes -Path $Path -Bytes $bytes -CapabilityRoot $capabilityRoot)
    } else {
        $afterSha = Get-CodexHookBytesSha256 -Bytes $bytes
        Set-CodexHookAtomicFileBytesWithCapability -Path $Path -Bytes $bytes -ExpectedExists $true -ExpectedSha256 ([string]$snapshot.sha256) -ExpectedIdentity ([string[]]$snapshot.identity) -AfterSha256 $afterSha -CapabilityRoot $capabilityRoot -AllowedExactPaths @($Path) -Scope 'evidence manifest publish'
        Set-ProtectedAclWithCapability -Path $Path -CapabilityRoot $capabilityRoot
    }
}

function Get-RestoreImmutableState {
    param([System.Collections.IDictionary]$Manifest)

    # Retired hooks are deliberately irreversible.  Evidence retains their
    # audit trail in the mutable manifest, but a restore contract must never
    # grant authority to recreate them.
    [ordered]@{
        runId = [string]$Manifest.runId
        codexHome = [string]$Manifest.codexHome
        originalHashes = $Manifest.originalHashes
        preservedHookTree = @($Manifest.preservedHookTree)
        intendedResources = $Manifest.intendedResources
        committedResources = @($Manifest.committedResources)
        retiredResources = @()
        aclTargets = @($Manifest.aclTargets)
        aclAppliedStates = $Manifest.aclAppliedStates
    }
}

function Get-CanonicalJsonSha256 {
    param([object]$Value)
    Get-TextSha256 -Content ($Value | ConvertTo-Json -Depth 40 -Compress)
}

function Get-RequiredCapabilitySnapshot {
    param(
        [string]$Path,
        [string]$CapabilityRoot,
        [string]$Name
    )

    $snapshot = Get-CodexHookCapabilityFileSnapshot -Path $Path -CapabilityRoot $CapabilityRoot -AllowedExactPaths @($Path) -Name $Name
    if (-not $snapshot.exists -or $snapshot.state -cne 'regular-file' -or $null -eq $snapshot.bytes) { throw "$Name 必须是可稳定读取的常规文件" }
    $snapshot
}

function Convert-StrictUtf8SnapshotText {
    param([object]$Snapshot, [string]$Name)
    try { [Text.UTF8Encoding]::new($false, $true).GetString([byte[]]$Snapshot.bytes) }
    catch { throw "$Name 不是严格 UTF-8" }
}

function Protect-HostHookRestorePayload {
    param([System.Collections.IDictionary]$Payload)

    [byte[]]$plain = [Text.UTF8Encoding]::new($false).GetBytes(($Payload | ConvertTo-Json -Depth 40 -Compress))
    [byte[]]$entropy = [Text.UTF8Encoding]::new($false).GetBytes('codex-host-hook-reconciliation-v1/restore-contract')
    [byte[]]$cipher = [Security.Cryptography.ProtectedData]::Protect($plain, $entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    [ordered]@{ protection='dpapi-current-user-v1'; trustBoundary='same-windows-user'; data=[Convert]::ToBase64String($cipher) }
}

function Unprotect-HostHookRestorePayload {
    param([object]$Envelope)

    Assert-CodexHookExactProperties $Envelope @('protection','trustBoundary','data') 'host hook restore contract envelope'
    if ($Envelope.protection -cne 'dpapi-current-user-v1' -or $Envelope.trustBoundary -cne 'same-windows-user' -or $Envelope.data -isnot [string]) { throw 'host hook restore contract envelope 非法' }
    try {
        [byte[]]$entropy = [Text.UTF8Encoding]::new($false).GetBytes('codex-host-hook-reconciliation-v1/restore-contract')
        [byte[]]$plain = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String([string]$Envelope.data), $entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($plain)
        Assert-CodexHookStrictJsonText -JsonText $text
        $text | ConvertFrom-Json -Depth 64 -DateKind String
    } catch { throw 'host hook restore contract 认证失败' }
}

function Write-NewOnlyProtectedBytes {
    param(
        [string]$Path,
        [byte[]]$Bytes,
        [string]$CapabilityRoot
    )

    $fullPath = Assert-CodexHookCapabilityPath -Path $Path -CapabilityRoot $CapabilityRoot -AllowedExactPaths @($Path) -Name 'protected evidence file'
    $parent = [IO.Path]::GetDirectoryName($fullPath)
    $guard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire($CapabilityRoot, $parent, $false)
    $tempPath = Join-Path $parent ".evidence-$([guid]::NewGuid().ToString('N')).tmp"
    $temp = $null
    try {
        Invoke-FixtureEvidenceAncestorReplace -ProtectedParent $parent
        $temp = $guard.CreateTempFile($tempPath)
        $temp.WriteAndFlush($Bytes)
        Set-ProtectedAclCurrentUserOwner -Path $tempPath
        $currentSddl = [string]$temp.GetSecurityDescriptorSddl()
        $desiredSddl = Get-ProtectedAclSddl -CurrentSddl $currentSddl -IsDirectory $false
        if ($currentSddl -cne $desiredSddl) { $temp.SetSecurityDescriptorSddl($currentSddl, $desiredSddl) }
        $temp.RenameTo($fullPath, $false)
        if ((Get-CodexHookBytesSha256 -Bytes ([byte[]]$temp.ReadAllBytesFromHandle())) -cne (Get-CodexHookBytesSha256 -Bytes $Bytes)) { throw 'protected evidence same-handle byte postcheck 失败' }
        if ([string]$temp.GetSecurityDescriptorSddl() -cne $desiredSddl) { throw 'protected evidence same-handle ACL postcheck 失败' }
        Get-CodexHookBytesSha256 -Bytes $Bytes
    } finally {
        if ($null -ne $temp) { $temp.Dispose() }
        $guard.Dispose()
        if ([IO.File]::Exists($tempPath)) { [IO.File]::Delete($tempPath) }
    }
}

function Write-NewOnlyProtectedJson {
    param([string]$Path, [object]$Value, [string]$CapabilityRoot)

    [byte[]]$bytes = [Text.UTF8Encoding]::new($false).GetBytes((($Value | ConvertTo-Json -Depth 40 -Compress) + "`n"))
    Write-NewOnlyProtectedBytes -Path $Path -Bytes $bytes -CapabilityRoot $CapabilityRoot
}

function New-HostHookRestoreContract {
    param(
        [string]$ResolvedCodexHome,
        [string]$EvidencePath,
        [System.Collections.IDictionary]$Manifest
    )

    $canonicalEvidence = [IO.Path]::GetFullPath($EvidencePath).TrimEnd('\')
    $runId = [IO.Path]::GetFileName($canonicalEvidence)
    if ($runId -cnotmatch '^\d{8}T\d{6}\.\d{3}Z-[0-9a-f]{8}$') { throw 'restore contract runId 格式非法' }
    if ($runId -cne [string]$Manifest.runId) { throw 'restore contract runId 与 canonical evidence leaf 不一致' }
    $aclBeforePath = Join-Path $canonicalEvidence 'acl-before.json'
    $aclBeforeSnapshot = Get-RequiredCapabilitySnapshot -Path $aclBeforePath -CapabilityRoot $canonicalEvidence -Name 'restore contract ACL backup snapshot'
    if (([string]$aclBeforeSnapshot.sha256).ToLowerInvariant() -cne ([string]$Manifest.originalHashes.'acl-before.json').ToLowerInvariant()) { throw 'restore contract ACL backup hash 漂移' }
    $aclBeforeText = Convert-StrictUtf8SnapshotText -Snapshot $aclBeforeSnapshot -Name 'restore contract ACL backup'
    Assert-CodexHookStrictJsonText -JsonText $aclBeforeText
    $aclBefore = $aclBeforeText | ConvertFrom-Json -AsHashtable -Depth 16 -DateKind String
    $sourceFiles = @($script:HostPreflightManifest.files | ForEach-Object {
        [ordered]@{ relativePath=[string]$_.relativePath; liveRelativePath=[string]$_.liveRelativePath; sha256=([string]$_.sha256).ToLowerInvariant() }
    })
    if ($sourceFiles.Count -ne 12) { throw 'restore contract 必须绑定固定12个 source 文件' }
    $actionOrder = [Collections.Generic.List[string]]::new()
    if (@($Manifest.committedResources) -ccontains 'hooks.json') { $actionOrder.Add('hooks.json') }
    if (@($Manifest.committedResources) -ccontains 'environment:SERENA_HOME') { $actionOrder.Add('environment:SERENA_HOME') }
    foreach ($file in @(Get-OrderedManagedHookItems -Items @($script:HostPreflightManifest.files) -Direction Restore)) {
        $id = "managed:$($file.liveRelativePath)"
        if (@($Manifest.committedResources) -ccontains $id) { $actionOrder.Add($id) }
    }
    foreach ($id in @('config.toml','codex-file-tools.yml')) { if (@($Manifest.committedResources) -ccontains $id) { $actionOrder.Add($id) } }
    $hookRootPath = [IO.Path]::GetFullPath((Join-Path $ResolvedCodexHome 'hooks')).TrimEnd('\')
    $aclActionOrdinal = 0
    $orderedAclActions = @($Manifest.aclTargets | ForEach-Object {
        $path = [string]$_
        [pscustomobject]@{ path=$path; depth=@([IO.Path]::GetFullPath($path).TrimEnd('\') -split '[\\/]').Count; ordinal=$aclActionOrdinal++ }
    } | Sort-Object depth,ordinal)
    foreach ($aclAction in @($orderedAclActions | Where-Object { [IO.Path]::GetFullPath([string]$_.path).TrimEnd('\').Equals($hookRootPath, [StringComparison]::OrdinalIgnoreCase) })) {
        if ($aclBefore.Contains($aclAction.path) -and (Get-RestoreImmutableState -Manifest $Manifest).aclAppliedStates.Contains($aclAction.path)) { $actionOrder.Add("acl:$($aclAction.path)") }
    }
    foreach ($aclAction in @($orderedAclActions | Where-Object { -not [IO.Path]::GetFullPath([string]$_.path).TrimEnd('\').Equals($hookRootPath, [StringComparison]::OrdinalIgnoreCase) })) {
        if ($aclBefore.Contains($aclAction.path) -and (Get-RestoreImmutableState -Manifest $Manifest).aclAppliedStates.Contains($aclAction.path)) { $actionOrder.Add("acl:$($aclAction.path)") }
    }
    $immutableState = Get-RestoreImmutableState -Manifest $Manifest
    $payload = [ordered]@{
        artifactType = 'env-governance.codex-host-hook-restore-contract'
        schemaVersion = 1
        runId = $runId
        codexHome = $ResolvedCodexHome
        evidencePath = $canonicalEvidence
        hostManifestSha256 = ([string](Get-RequiredCapabilitySnapshot -Path $script:HostPreflightManifestPath -CapabilityRoot $script:ProjectRoot -Name 'restore host manifest snapshot').sha256).ToLowerInvariant()
        sourceFiles = $sourceFiles
        immutableStateSha256 = (Get-CanonicalJsonSha256 -Value $immutableState).ToLowerInvariant()
        immutableState = $immutableState
        actionOrder = $actionOrder.ToArray()
    }
    $envelope = Protect-HostHookRestorePayload -Payload $payload
    $contractPath = Join-Path $canonicalEvidence 'restore-contract.json'
    $contractSha = (Write-NewOnlyProtectedJson -Path $contractPath -Value $envelope -CapabilityRoot $canonicalEvidence).ToLowerInvariant()
    $evidenceRoot = [IO.Path]::GetDirectoryName($canonicalEvidence)
    $claimsRoot = Join-Path $evidenceRoot '.claims'
    $claimScope = Resolve-CodexHostHookEvidenceScope -ResolvedCodexHome $ResolvedCodexHome
    [void](New-CodexHookCapabilityDirectory -Path $claimsRoot -CapabilityRoot $claimScope.capabilityRoot -Name 'restore claims root')
    Assert-NoReparsePath -Path $claimsRoot -RequireLeaf | Out-Null
    Set-ProtectedAclWithCapability -Path $claimsRoot -CapabilityRoot $claimScope.capabilityRoot
    $claim = [ordered]@{ artifactType='env-governance.codex-host-hook-restore-claim'; schemaVersion=1; runId=$runId; evidencePath=$canonicalEvidence; restoreContractSha256=$contractSha }
    $claimPath = Join-Path $claimsRoot "$runId.json"
    $claimSha = (Write-NewOnlyProtectedJson -Path $claimPath -Value $claim -CapabilityRoot $claimsRoot).ToLowerInvariant()
    [pscustomobject]@{ contractPath=$contractPath; contractSha256=$contractSha; claimPath=$claimPath; claimSha256=$claimSha; payload=$payload }
}

function Read-HostHookRestoreContract {
    param(
        [string]$ResolvedCodexHome,
        [object]$Evidence,
        [System.Collections.IDictionary]$Manifest
    )

    $runId = [IO.Path]::GetFileName([string]$Evidence.path)
    $contractPath = Join-Path ([string]$Evidence.path) 'restore-contract.json'
    $claimPath = Join-Path ([IO.Path]::GetDirectoryName([string]$Evidence.path)) ".claims\$runId.json"
    foreach ($path in @($contractPath,$claimPath)) { Assert-NoReparsePath -Path $path -RequireLeaf | Out-Null }
    if ($runId -cnotmatch '^\d{8}T\d{6}\.\d{3}Z-[0-9a-f]{8}$') { throw 'host hook restore runId 格式非法' }
    $contractSnapshot = Get-RequiredCapabilitySnapshot -Path $contractPath -CapabilityRoot ([string]$Evidence.path) -Name 'host hook restore contract snapshot'
    $contractText = Convert-StrictUtf8SnapshotText -Snapshot $contractSnapshot -Name 'host hook restore contract'
    Assert-CodexHookStrictJsonText -JsonText $contractText
    $contractEnvelope = $contractText | ConvertFrom-Json -Depth 8 -DateKind String
    $payload = Unprotect-HostHookRestorePayload -Envelope $contractEnvelope
    Assert-CodexHookExactProperties $payload @('artifactType','schemaVersion','runId','codexHome','evidencePath','hostManifestSha256','sourceFiles','immutableStateSha256','immutableState','actionOrder') 'host hook restore contract payload'
    $claimSnapshot = Get-RequiredCapabilitySnapshot -Path $claimPath -CapabilityRoot ([IO.Path]::GetDirectoryName([string]$Evidence.path)) -Name 'host hook restore claim snapshot'
    $claimText = Convert-StrictUtf8SnapshotText -Snapshot $claimSnapshot -Name 'host hook restore claim'
    Assert-CodexHookStrictJsonText -JsonText $claimText
    $claim = $claimText | ConvertFrom-Json -Depth 8 -DateKind String
    Assert-CodexHookExactProperties $claim @('artifactType','schemaVersion','runId','evidencePath','restoreContractSha256') 'host hook restore claim'
    $contractSha = ([string]$contractSnapshot.sha256).ToLowerInvariant()
    if ($payload.artifactType -cne 'env-governance.codex-host-hook-restore-contract' -or [int]$payload.schemaVersion -ne 1 -or $payload.runId -cne $runId -or $payload.codexHome -cne $ResolvedCodexHome -or $payload.evidencePath -cne [string]$Evidence.path) { throw 'host hook restore contract binding 非法' }
    if ($claim.artifactType -cne 'env-governance.codex-host-hook-restore-claim' -or [int]$claim.schemaVersion -ne 1 -or $claim.runId -cne $runId -or $claim.evidencePath -cne [string]$Evidence.path -or $claim.restoreContractSha256 -cne $contractSha) { throw 'host hook restore claim binding 非法' }
    $hostManifestSnapshot = Get-RequiredCapabilitySnapshot -Path $script:HostPreflightManifestPath -CapabilityRoot $script:ProjectRoot -Name 'restore current host manifest snapshot'
    if ($payload.hostManifestSha256 -cne ([string]$hostManifestSnapshot.sha256).ToLowerInvariant()) { throw 'host hook restore contract host manifest 漂移' }
    if (@($payload.sourceFiles).Count -ne 12) { throw 'host hook restore contract source closure 非法' }
    for ($i=0; $i -lt 12; $i++) {
        $expected = $script:HostPreflightManifest.files[$i]
        $actual = $payload.sourceFiles[$i]
        Assert-CodexHookExactProperties $actual @('relativePath','liveRelativePath','sha256') "host hook restore source[$i]"
        if ($actual.relativePath -cne [string]$expected.relativePath -or $actual.liveRelativePath -cne [string]$expected.liveRelativePath -or $actual.sha256 -cne ([string]$expected.sha256).ToLowerInvariant()) { throw 'host hook restore contract source binding 非法' }
    }
    if ($payload.immutableStateSha256 -cne (Get-CanonicalJsonSha256 -Value $payload.immutableState).ToLowerInvariant() -or $payload.immutableStateSha256 -cne (Get-CanonicalJsonSha256 -Value (Get-RestoreImmutableState -Manifest $Manifest)).ToLowerInvariant()) { throw 'host hook restore immutable state 认证绑定非法' }
    $payload
}

function New-EvidenceSnapshot {
    param(
        [string]$ResolvedCodexHome,
        [object]$State
    )

    $snapshot = New-CodexHostHookEvidenceSnapshot `
        -ResolvedCodexHome $ResolvedCodexHome `
        -State $State `
        -RetiredProjectTrusts @($script:HostPreflightManifest.retiredProjectTrusts)
    $script:CurrentEvidencePath = $snapshot.path
    $snapshot
}

function Invoke-Repair {
    param(
        [string]$ResolvedCodexHome,
        [object]$InitialState
    )

    if ($InitialState.ok) {
        return New-Result -ResultMode "Repair" -State $InitialState -Changed $false -EvidencePath $null
    }
    $unavailableRuntimeIds = @($InitialState.runtimeDependencyStates | Where-Object { -not $_.ok } | ForEach-Object { [string]$_.id })
    if ($unavailableRuntimeIds.Count -gt 0) {
        throw "受管 hook runtime dependency 不可用，Repair 在 evidence 前拒绝：$($unavailableRuntimeIds -join ',')"
    }

    $originalConfigAcl = Get-Acl -LiteralPath $InitialState.configPath
    $originalHooksAcl = Get-Acl -LiteralPath $InitialState.hooksPath
    $originalSerenaContextAcl = Get-Acl -LiteralPath $InitialState.serenaContextPath
    # A rollback must never resurrect an explicitly retired project trust.
    # Keep every other original config byte unchanged so the transaction still
    # restores the pre-Repair state as narrowly as possible.
    $rollbackConfigContent = Remove-RetiredProjectTrustFromContent `
        -Content ([string]$InitialState.configContent) `
        -RetiredProjectTrusts @($script:HostPreflightManifest.retiredProjectTrusts)
    $snapshot = New-EvidenceSnapshot -ResolvedCodexHome $ResolvedCodexHome -State $InitialState
    $manifest = $snapshot.manifest
    $committed = [System.Collections.Generic.List[string]]::new()
    $attempted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $managedTargetPaths = @($InitialState.managedFileStates | ForEach-Object { [string]$_.targetPath })
    $managedTargetSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($managedTargetPath in $managedTargetPaths) { [void]$managedTargetSet.Add([IO.Path]::GetFullPath($managedTargetPath)) }
    if ($managedTargetPaths.Count -ne 12 -or $managedTargetSet.Count -ne 12) {
        throw '受管 hook 发布 capability 必须精确包含12个唯一目标。'
    }
    $createdManagedDirectories = @{}

    try {
        $manifest.status = "applying"
        Write-Manifest -Path $snapshot.manifestPath -Manifest $manifest
        if ($InitialState.desiredSerenaContext.changed) {
            if ((Get-Sha256 -Path $InitialState.serenaContextPath) -ne $snapshot.livePreconditionHashes["codex-file-tools.yml"]) {
                throw "codex-file-tools.yml 在修复前置校验后发生并发变化"
            }
            $attempted.Add("codex-file-tools.yml") | Out-Null
            $manifest.attemptedResources = @($attempted)
            Write-Manifest -Path $snapshot.manifestPath -Manifest $manifest
            Write-AtomicText `
                -Path $InitialState.serenaContextPath `
                -Content $InitialState.desiredSerenaContext.content `
                -ExpectedCurrentSha256 $snapshot.livePreconditionHashes["codex-file-tools.yml"] `
                -ExpectedCurrentSddl $originalSerenaContextAcl.Sddl
            $validatedSerenaContext = Get-DesiredSerenaContext -Content (Read-Text -Path $InitialState.serenaContextPath)
            if ($validatedSerenaContext.changed) { throw "codex-file-tools.yml 原子替换后未通过自验证" }
            $committed.Add("codex-file-tools.yml")
            $manifest.committedResources = $committed.ToArray()
            Write-Manifest -Path $snapshot.manifestPath -Manifest $manifest
        }
        if ($InitialState.desiredConfig.changed) {
            if ((Get-Sha256 -Path $InitialState.configPath) -ne $snapshot.livePreconditionHashes["config.toml"]) {
                throw "config.toml 在修复前置校验后发生并发变化"
            }
            $attempted.Add("config.toml") | Out-Null
            $manifest.attemptedResources = @($attempted)
            Write-Manifest -Path $snapshot.manifestPath -Manifest $manifest
            Write-AtomicText `
                -Path $InitialState.configPath `
                -Content $InitialState.desiredConfig.content `
                -ExpectedCurrentSha256 $snapshot.livePreconditionHashes["config.toml"] `
                -ExpectedCurrentSddl $originalConfigAcl.Sddl
            $validatedConfig = Get-DesiredConfig -Content (Read-Text -Path $InitialState.configPath) -ExpectedSerenaContextPath $InitialState.serenaContextPath
            if ($validatedConfig.changed) {
                throw "config.toml 原子替换后未通过自验证"
            }
            # The reconciler owns selected config semantics, not the vendor
            # file's long-term ACL policy. Preserve the metadata observed at
            # transaction start instead of silently widening or hardening it.
            $committed.Add("config.toml")
            $manifest.committedResources = $committed.ToArray()
            Write-Manifest -Path $snapshot.manifestPath -Manifest $manifest
        }

        $managedPublishStates = @(Get-OrderedManagedHookItems -Items @($InitialState.managedFileStates | Where-Object { -not $_.ok }) -Direction Repair)
        foreach ($fileState in $managedPublishStates) {
            $resourceName = "managed:$($fileState.liveRelativePath)"
            $attempted.Add($resourceName) | Out-Null
            $manifest.attemptedResources = @($attempted)
            Write-Manifest -Path $snapshot.manifestPath -Manifest $manifest
            $targetParent = Split-Path -Parent ([string]$fileState.targetPath)
            if ($fileState.targetParentExisted) {
                [void](New-CodexHookCapabilityDirectory -Path $targetParent -CapabilityRoot $InitialState.hookDirectory -Name "managed parent $($fileState.liveRelativePath)")
            } else {
                if (-not $createdManagedDirectories.ContainsKey($targetParent)) {
                    [void](New-CodexHookCapabilityDirectory -Path $targetParent -CapabilityRoot $InitialState.hookDirectory -Name "managed parent $($fileState.liveRelativePath)" -RequireMissing)
                    $createdDirectoryGuard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire($InitialState.hookDirectory, $targetParent, $false)
                    try {
                        $createdManagedDirectories[$targetParent] = [pscustomobject][ordered]@{
                            path = $targetParent
                            volumeSerialNumber = [string]$createdDirectoryGuard.VolumeSerialNumber
                            fileIndex = [string]$createdDirectoryGuard.FileIndex
                        }
                    } finally {
                        $createdDirectoryGuard.Dispose()
                    }
                }
            }
            [byte[]]$sourceBytes = [byte[]]$fileState.sourceBytes
            if ((Get-CodexHookBytesSha256 -Bytes $sourceBytes) -cne [string]$fileState.sourceRawSha256) {
                throw "managed source snapshot hash 不一致：$($fileState.liveRelativePath)"
            }
            Set-CodexHookAtomicFileBytesWithCapability `
                -Path ([string]$fileState.targetPath) `
                -Bytes $sourceBytes `
                -ExpectedExists ([bool]$fileState.targetExists) `
                -ExpectedSha256 ([string]$fileState.targetRawSha256) `
                -AfterSha256 ([string]$fileState.sourceRawSha256) `
                -CapabilityRoot $InitialState.hookDirectory `
                -AllowedExactPaths $managedTargetPaths `
                -Scope "managed publish $($fileState.liveRelativePath)" `
                -BeforeMove { param($targetPath) Invoke-FixtureManagedParentAttack -TargetParent (Split-Path -Parent $targetPath) } `
                -AfterRename $(if ($fileState.targetExists) {
                    $beforeManagedKey = ([string]$fileState.liveRelativePath).Replace('/', '\')
                    $beforeManagedSddl = [string]$manifest.originalHashes.managedHooks[$beforeManagedKey].sddl
                    { param($publishedLease, $publishedPath)
                        $currentSddl = [string]$publishedLease.GetSecurityDescriptorSddl()
                        if ($currentSddl -cne $beforeManagedSddl) { $publishedLease.SetSecurityDescriptorSddl($currentSddl, $beforeManagedSddl) }
                        if ([string]$publishedLease.GetSecurityDescriptorSddl() -cne $beforeManagedSddl) { throw 'managed publish ACL same-handle postcheck 失败' }
                    }.GetNewClosure()
                } else { $null })
            $committed.Add($resourceName)
            $manifest.committedResources = $committed.ToArray()
            Write-Manifest -Path $snapshot.manifestPath -Manifest $manifest
            Invoke-FixturePostCommitFailure -Phase 'managed'
        }

        if (-not $InitialState.environmentState.ok) {
            $attempted.Add('environment:SERENA_HOME') | Out-Null
            $manifest.attemptedResources = @($attempted)
            Write-Manifest -Path $snapshot.manifestPath -Manifest $manifest
            Set-SerenaEnvironmentValue -ResolvedCodexHome $ResolvedCodexHome -Value 'D:\Codex\.serena' -ValueKind 'String' -ExpectedValue ([string]$InitialState.environmentState.value) -ExpectedValueKind ([string]$InitialState.environmentState.valueKind)
            $committed.Add('environment:SERENA_HOME')
            $manifest.committedResources = $committed.ToArray()
            Write-Manifest -Path $snapshot.manifestPath -Manifest $manifest
            Invoke-FixturePostCommitFailure -Phase 'environment'
        }

        if ($InitialState.desiredHooks.changed) {
            if ((Get-Sha256 -Path $InitialState.hooksPath) -ne $snapshot.livePreconditionHashes["hooks.json"]) {
                throw "hooks.json 在修复前置校验后发生并发变化"
            }
            $attempted.Add("hooks.json") | Out-Null
            $manifest.attemptedResources = @($attempted)
            Write-Manifest -Path $snapshot.manifestPath -Manifest $manifest
            Write-AtomicText `
                -Path $InitialState.hooksPath `
                -Content $InitialState.desiredHooks.content `
                -ExpectedCurrentSha256 $snapshot.livePreconditionHashes["hooks.json"] `
                -ExpectedCurrentSddl $originalHooksAcl.Sddl
            $validatedHooks = Get-DesiredHooksJson -Content (Read-Text -Path $InitialState.hooksPath)
            if ($validatedHooks.changed) {
                throw "hooks.json 原子替换后未通过自验证"
            }
            $committed.Add("hooks.json")
            $manifest.committedResources = $committed.ToArray()
            Write-Manifest -Path $snapshot.manifestPath -Manifest $manifest
            Invoke-FixturePostCommitFailure -Phase 'registry'
        }
    } catch {
        $failure = $_
        $rollbackErrors = [System.Collections.Generic.List[string]]::new()
        $concurrentReplace = Get-ConcurrentReplaceRecord -Exception $failure.Exception
        $concurrentReplacePath = if ($null -eq $concurrentReplace) { "" } else { $concurrentReplace.path }
        $manifest.concurrentReplace = $concurrentReplace
        if ($attempted.Contains("codex-file-tools.yml") -and -not $concurrentReplacePath.Equals($InitialState.serenaContextPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            try {
                $currentSerenaContext = Read-Text -Path $InitialState.serenaContextPath
                if ($currentSerenaContext.Equals($InitialState.desiredSerenaContext.content, [System.StringComparison]::Ordinal)) {
                    Write-AtomicText `
                        -Path $InitialState.serenaContextPath `
                        -Content $InitialState.serenaContextContent `
                        -ExpectedCurrentSha256 $manifest.intendedResources["codex-file-tools.yml"] `
                        -ExpectedCurrentSddl $originalSerenaContextAcl.Sddl
                } elseif (-not $currentSerenaContext.Equals($InitialState.serenaContextContent, [System.StringComparison]::Ordinal)) {
                    throw "检测到非本次 Repair 写入的并发内容，拒绝覆盖"
                }
            } catch {
                $rollbackConcurrent = Get-ConcurrentReplaceRecord -Exception $_.Exception
                if ($null -ne $rollbackConcurrent) { $manifest.rollbackConcurrentReplaces = @($manifest.rollbackConcurrentReplaces) + @($rollbackConcurrent) }
                $rollbackErrors.Add("codex-file-tools.yml: $($_.Exception.Message)")
            }
        } elseif ($attempted.Contains("codex-file-tools.yml")) {
            $rollbackErrors.Add("codex-file-tools.yml: 并发版本已保留，拒绝用旧快照覆盖")
        }
        if ($attempted.Contains("config.toml") -and -not $concurrentReplacePath.Equals($InitialState.configPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            try {
                $currentConfig = Read-Text -Path $InitialState.configPath
                if ($currentConfig.Equals($InitialState.desiredConfig.content, [System.StringComparison]::Ordinal)) {
                    Write-AtomicText `
                        -Path $InitialState.configPath `
                        -Content $rollbackConfigContent `
                        -ExpectedCurrentSha256 $manifest.intendedResources["config.toml"] `
                        -ExpectedCurrentSddl $originalConfigAcl.Sddl
                } elseif (-not $currentConfig.Equals($rollbackConfigContent, [System.StringComparison]::Ordinal)) {
                    throw "检测到非本次 Repair 写入的并发内容，拒绝覆盖"
                }
            } catch {
                $rollbackConcurrent = Get-ConcurrentReplaceRecord -Exception $_.Exception
                if ($null -ne $rollbackConcurrent) {
                    $manifest.rollbackConcurrentReplaces = @($manifest.rollbackConcurrentReplaces) + @($rollbackConcurrent)
                }
                $rollbackErrors.Add("config.toml: $($_.Exception.Message)")
            }
        } elseif ($attempted.Contains("config.toml")) {
            $rollbackErrors.Add("config.toml: 并发版本已保留，拒绝用旧快照覆盖")
        }
        if ($attempted.Contains("hooks.json") -and -not $concurrentReplacePath.Equals($InitialState.hooksPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            try {
                $currentHooks = Read-Text -Path $InitialState.hooksPath
                if ($currentHooks.Equals($InitialState.desiredHooks.content, [System.StringComparison]::Ordinal)) {
                    Write-AtomicText `
                        -Path $InitialState.hooksPath `
                        -Content $InitialState.hooksContent `
                        -ExpectedCurrentSha256 $manifest.intendedResources["hooks.json"] `
                        -ExpectedCurrentSddl $originalHooksAcl.Sddl
                } elseif (-not $currentHooks.Equals($InitialState.hooksContent, [System.StringComparison]::Ordinal)) {
                    throw "检测到非本次 Repair 写入的并发内容，拒绝覆盖"
                }
            } catch {
                $rollbackConcurrent = Get-ConcurrentReplaceRecord -Exception $_.Exception
                if ($null -ne $rollbackConcurrent) {
                    $manifest.rollbackConcurrentReplaces = @($manifest.rollbackConcurrentReplaces) + @($rollbackConcurrent)
                }
                $rollbackErrors.Add("hooks.json: $($_.Exception.Message)")
            }
        } elseif ($attempted.Contains("hooks.json")) {
            $rollbackErrors.Add("hooks.json: 并发版本已保留，拒绝用旧快照覆盖")
        }

        if ($attempted.Contains('environment:SERENA_HOME')) {
            try {
                $currentEnvironment = Get-SerenaEnvironmentState -ResolvedCodexHome $ResolvedCodexHome
                if ([string]$currentEnvironment.value -ceq 'D:\Codex\.serena') {
                    if (-not (Test-IsLiveCodexHome -ResolvedCodexHome $ResolvedCodexHome)) {
                        Write-AtomicText -Path ([string]$InitialState.environmentState.fixturePath) -Content ([string]$InitialState.environmentState.fixtureContent) -ExpectedCurrentSha256 ([string]$currentEnvironment.fixtureSha256) -ExpectedCurrentSddl ([string]$currentEnvironment.fixtureSddl)
                    } else {
                        Set-SerenaEnvironmentValue -ResolvedCodexHome $ResolvedCodexHome -Value ([string]$InitialState.environmentState.value) -ValueKind ([string]$InitialState.environmentState.valueKind) -ExpectedValue 'D:\Codex\.serena' -ExpectedValueKind 'String'
                    }
                } elseif ([string]$currentEnvironment.value -cne [string]$InitialState.environmentState.value) {
                    throw '检测到非本次 Repair 写入的 SERENA_HOME，拒绝覆盖'
                }
            } catch {
                $rollbackErrors.Add("environment:SERENA_HOME: $($_.Exception.Message)")
            }
        }
        $managedRollbackStates = @(Get-OrderedManagedHookItems -Items @($InitialState.managedFileStates | Where-Object { $attempted.Contains("managed:$($_.liveRelativePath)") }) -Direction Restore)
        foreach ($fileState in $managedRollbackStates) {
            try {
                $currentSnapshot = Get-CodexHookCapabilityFileSnapshot -Path ([string]$fileState.targetPath) -CapabilityRoot $InitialState.hookDirectory -AllowedExactPaths $managedTargetPaths -Name "rollback snapshot $($fileState.liveRelativePath)"
                $currentHash = [string]$currentSnapshot.sha256
                if ($currentHash -ceq [string]$fileState.sourceRawSha256) {
                    if ($fileState.targetExists) {
                        $backupKey = ([string]$fileState.liveRelativePath).Replace('/', '\')
                        $backup = $manifest.originalHashes.managedHooks[$backupKey]
                        [byte[]]$backupBytes = [IO.File]::ReadAllBytes([string]$backup.backupPath)
                        $backupSha256 = Get-CodexHookBytesSha256 -Bytes $backupBytes
                        if ($backupSha256 -cne [string]$backup.sha256) { throw '受管 hook rollback backup hash 不一致' }
                        Set-CodexHookAtomicFileBytesWithCapability `
                            -Path ([string]$fileState.targetPath) `
                            -Bytes $backupBytes `
                            -ExpectedExists $true `
                            -ExpectedSha256 ([string]$fileState.sourceRawSha256) `
                            -AfterSha256 $backupSha256 `
                            -CapabilityRoot $InitialState.hookDirectory `
                            -AllowedExactPaths $managedTargetPaths `
                            -Scope "rollback $($fileState.liveRelativePath)" `
                            -AfterRename {
                                param($publishedLease, $publishedPath)
                                $beforeSddl = [string]$backup.sddl
                                Set-AclOwnerAndGroupFromSddl -Path $publishedPath -Sddl $beforeSddl
                                $currentSddl = [string]$publishedLease.GetSecurityDescriptorSddl()
                                if ($currentSddl -cne $beforeSddl) { $publishedLease.SetSecurityDescriptorSddl($currentSddl, $beforeSddl) }
                                if ([string]$publishedLease.GetSecurityDescriptorSddl() -cne $beforeSddl) { throw 'managed rollback ACL same-handle postcheck 失败' }
                            }
                    } else {
                        Remove-CodexHookCapabilityFile -Path ([string]$fileState.targetPath) -CapabilityRoot $InitialState.hookDirectory -AllowedExactPaths $managedTargetPaths -ExpectedSha256 ([string]$fileState.sourceRawSha256) -Scope "rollback $($fileState.liveRelativePath)"
                    }
                } elseif ([bool]$fileState.targetExists -and $currentHash -ceq [string]$fileState.targetRawSha256 -and [string]$currentSnapshot.sddl -cne [string]$manifest.originalHashes.managedHooks[([string]$fileState.liveRelativePath).Replace('/', '\')].sddl) {
                    throw '检测到 managed rollback before bytes 的第三方 ACL，拒绝接纳'
                } elseif ($currentHash -cne [string]$fileState.targetRawSha256) {
                    throw '检测到非本次 Repair 写入的受管 hook 文件，拒绝覆盖'
                }
            } catch {
                $rollbackErrors.Add("managed:$($fileState.liveRelativePath): $($_.Exception.Message)")
            }
        }
        $managedDirectories = @($createdManagedDirectories.Keys | Sort-Object Length -Descending)
        foreach ($directory in $managedDirectories) {
            if ($directory.Equals($InitialState.hookDirectory, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            try {
                Invoke-FixtureCreatedDirectoryCleanupReplace -TargetParent $directory
                $expectedDirectory = $createdManagedDirectories[$directory]
                $deleteGuard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::AcquireForEmptyDelete($InitialState.hookDirectory, $directory)
                try {
                    if (
                        [string]$deleteGuard.VolumeSerialNumber -cne [string]$expectedDirectory.volumeSerialNumber -or
                        [string]$deleteGuard.FileIndex -cne [string]$expectedDirectory.fileIndex
                    ) {
                        throw '本次创建目录 identity 漂移，拒绝删除替代目录。'
                    }
                    $deleteGuard.DeleteEmptyDirectory()
                } finally {
                    $deleteGuard.Dispose()
                }
            } catch {
                $rollbackErrors.Add("managed-directory:${directory}: $($_.Exception.Message)")
            }
        }

        $manifest.status = if ($rollbackErrors.Count -eq 0) { "rolled-back" } else { "unsafe-partial" }
        $manifest.error = $failure.Exception.Message
        if ($rollbackErrors.Count -gt 0) {
            $manifest.rollbackErrors = $rollbackErrors.ToArray()
        }
        Write-Manifest -Path $snapshot.manifestPath -Manifest $manifest
        if ($rollbackErrors.Count -gt 0) {
            throw "修复失败且回滚不完整：$($rollbackErrors -join '; ')"
        }
        throw $failure
    }

    try {
        $postCommitSerenaContext = Get-DesiredSerenaContext -Content (Read-Text -Path $InitialState.serenaContextPath)
        $postCommitConfig = Get-DesiredConfig -Content (Read-Text -Path $InitialState.configPath) -ExpectedSerenaContextPath $InitialState.serenaContextPath
        $postCommitHooks = Get-DesiredHooksJson -Content (Read-Text -Path $InitialState.hooksPath)
        if ($postCommitSerenaContext.changed -or $postCommitConfig.changed -or $postCommitHooks.changed) {
            throw "三资源提交完成后目标状态被并发改写"
        }

        $retiredPathSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($name in $InitialState.legacyPresent) { [void]$retiredPathSet.Add((Join-Path $InitialState.hookDirectory $name)) }
        foreach ($name in $InitialState.legacyDirectoriesPresent) { [void]$retiredPathSet.Add((Join-Path $InitialState.hookDirectory $name)) }
        $aclTargets = @(
            $InitialState.hooksPath,
            $InitialState.serenaContextPath,
            $InitialState.hookDirectory
        ) + @(
            Get-ChildItem -LiteralPath $InitialState.hookDirectory -Recurse -Force | Where-Object {
                $candidate = $_.FullName
                -not $retiredPathSet.Contains($candidate)
            } | ForEach-Object { $_.FullName }
        )
        $aclApplied = [System.Collections.Generic.List[string]]::new()
        foreach ($path in $aclTargets) {
            Assert-NoReparsePath -Path $path -RequireLeaf | Out-Null
            if ($null -ne $script:FixtureForbiddenAclPath -and $path.Equals($script:FixtureForbiddenAclPath, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'fixture-only retired path ACL mutation forbidden' }
            Set-ProtectedAclCurrentUserOwner -Path $path
            $aclRecord = New-RestoreAclTargetLease -ResolvedCodexHome $ResolvedCodexHome -Path $path
            try {
                $currentSddl = [string]$aclRecord.currentSddl
                $desiredSddl = Get-ProtectedAclSddl -CurrentSddl $currentSddl -IsDirectory ([bool]$aclRecord.lease.IsDirectory)
                Invoke-FixtureAclCasReplace -TargetPath $path
                if ([string]$aclRecord.lease.GetSecurityDescriptorSddl() -cne $currentSddl) { throw 'Repair ACL same-handle prewrite CAS 发现竞争 ACL' }
                if ($currentSddl -cne $desiredSddl) {
                    $aclRecord.lease.SetSecurityDescriptorSddl($currentSddl, $desiredSddl)
                }
                $appliedSddl = [string]$aclRecord.lease.GetSecurityDescriptorSddl()
                $aclApplied.Add($path)
                $manifest.aclTargets = $aclApplied.ToArray()
                $manifest.aclAppliedStates[$path] = $appliedSddl
                Write-Manifest -Path $snapshot.manifestPath -Manifest $manifest
                Invoke-FixturePostCommitFailure -Phase "acl"
            } finally { Close-RestoreAclTargetLease -Record $aclRecord }
        }

        $retired = [System.Collections.Generic.List[string]]::new()
        $legacyAllowedPaths = @($script:LegacyHookNames | ForEach-Object { Join-Path $InitialState.hookDirectory $_ })
        foreach ($name in $InitialState.legacyPresent) {
            $livePath = Join-Path $InitialState.hookDirectory $name
            Assert-NoReparsePath -Path $livePath -RequireLeaf | Out-Null
            $legacySnapshot = Get-CodexHookCapabilityFileSnapshot `
                -Path $livePath `
                -CapabilityRoot $InitialState.hookDirectory `
                -AllowedExactPaths $legacyAllowedPaths `
                -Name "retire legacy $name"
            if (-not $legacySnapshot.exists -or [string]$legacySnapshot.state -cne 'regular-file') {
                throw "退役前 legacy target 不可安全删除：$name"
            }
            $expectedLegacySha256 = [string]$legacySnapshot.sha256
            Remove-CodexHookCapabilityFile `
                -Path $livePath `
                -ExpectedSha256 $expectedLegacySha256 `
                -CapabilityRoot $InitialState.hookDirectory `
                -AllowedExactPaths $legacyAllowedPaths `
                -Scope "retire legacy $name" `
                -TestAfterSnapshot { param($targetPath) Invoke-FixtureLegacyDeleteReplace -TargetPath $targetPath }
            $retired.Add($name)
            $manifest.retiredResources = $retired.ToArray()
            Write-Manifest -Path $snapshot.manifestPath -Manifest $manifest
            Invoke-FixturePostCommitFailure -Phase "legacy"
        }
        foreach ($directoryName in $InitialState.legacyDirectoriesPresent) {
            $legacyDirectoryPath = Join-Path $InitialState.hookDirectory $directoryName
            Assert-NoReparsePath -Path $legacyDirectoryPath -RequireLeaf | Out-Null
            $deleteGuard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::AcquireForEmptyDelete($InitialState.hookDirectory, $legacyDirectoryPath)
            try {
                Invoke-FixtureLegacyDirectoryReplace -TargetPath $legacyDirectoryPath -Phase delete
                $deleteGuard.DeleteEmptyDirectory()
            } finally { $deleteGuard.Dispose() }
            $retired.Add("$directoryName\")
            $manifest.retiredResources = $retired.ToArray()
            Write-Manifest -Path $snapshot.manifestPath -Manifest $manifest
            Invoke-FixturePostCommitFailure -Phase "legacy"
        }
        $manifest.retiredResources = $retired.ToArray()
        Invoke-FixturePostCommitFailure -Phase "final"

        $finalState = Get-ReconciliationState -ResolvedCodexHome $ResolvedCodexHome
        if (-not $finalState.ok) {
            throw "Repair 完成后仍有 $($finalState.driftCount) 类 drift"
        }
        $initialPreservedTree = @($InitialState.preservedHookTree) | ConvertTo-Json -Depth 4 -Compress
        $finalPreservedTree = @($finalState.preservedHookTree) | ConvertTo-Json -Depth 4 -Compress
        if ($initialPreservedTree -cne $finalPreservedTree) {
            throw "未知 hooks tree 的路径或内容在 Repair 期间发生变化"
        }

        $restoreArtifacts = New-HostHookRestoreContract -ResolvedCodexHome $ResolvedCodexHome -EvidencePath $snapshot.path -Manifest $manifest
        $manifest.restoreContractSha256 = [string]$restoreArtifacts.contractSha256
        $manifest.restoreClaimSha256 = [string]$restoreArtifacts.claimSha256
        [void](Read-HostHookRestoreContract -ResolvedCodexHome $ResolvedCodexHome -Evidence ([pscustomobject]@{ path=$snapshot.path }) -Manifest $manifest)
        $manifest.status = "completed"
        $manifest.completedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        Write-Manifest -Path $snapshot.manifestPath -Manifest $manifest
        New-Result -ResultMode "Repair" -State $finalState -Changed $true -EvidencePath $snapshot.path
    } catch {
        $postCommitFailure = $_
        $rollbackErrors = [Collections.Generic.List[string]]::new()
        $recoveryRequired = [Collections.Generic.List[string]]::new()
        $aclBefore = Get-Content -LiteralPath (Join-Path $snapshot.path 'acl-before.json') -Raw | ConvertFrom-Json -AsHashtable
        $aclRollbackOrdinal = 0
        $aclRollbackPaths = @($manifest.aclTargets | ForEach-Object {
            $aclRollbackPath = [string]$_
            [pscustomobject]@{ path=$aclRollbackPath; depth=@([IO.Path]::GetFullPath($aclRollbackPath).TrimEnd('\') -split '[\\/]').Count; ordinal=$aclRollbackOrdinal++ }
        } | Sort-Object -Property depth, ordinal | ForEach-Object { $_.path })
        $restoreRollbackAcl = {
            param([string]$Path)
            if (-not $aclBefore.ContainsKey($Path)) { return }
            $aclRecord = $null
            try {
                $aclRecord = New-RestoreAclTargetLease -ResolvedCodexHome $ResolvedCodexHome -Path $Path
                $currentSddl = [string]$aclRecord.lease.GetSecurityDescriptorSddl()
                $originalSddl = [string]$aclBefore[$Path]
                $appliedSddl = [string]$manifest.aclAppliedStates[$Path]
                if ($currentSddl -ceq $originalSddl) { return }
                Invoke-FixtureRollbackAclCasReplace -TargetPath $Path
                if ([string]$aclRecord.lease.GetSecurityDescriptorSddl() -cne $currentSddl) { throw 'Repair rollback ACL same-handle prewrite CAS 发现竞争 ACL' }
                if ($currentSddl -cne $appliedSddl) { throw '检测到第三方 ACL，拒绝覆盖' }
                Set-AclOwnerAndGroupFromSddl -Path $Path -Sddl $originalSddl
                $currentSddl = [string]$aclRecord.lease.GetSecurityDescriptorSddl()
                $aclRecord.lease.SetSecurityDescriptorSddl($currentSddl, $originalSddl)
                if ([string]$aclRecord.lease.GetSecurityDescriptorSddl() -cne $originalSddl) { throw 'ACL 恢复后校验失败' }
            } catch {
                $rollbackErrors.Add("acl:${Path}: $($_.Exception.Message)")
                $recoveryRequired.Add("acl:$Path")
            } finally { Close-RestoreAclTargetLease -Record $aclRecord }
        }

        # Restore ACL only when it is still exactly the ACL written by this run.
        foreach ($path in $aclRollbackPaths) {
            & $restoreRollbackAcl ([string]$path)
        }

        foreach ($resource in @(
            [pscustomobject]@{ name='codex-file-tools.yml'; path=$InitialState.serenaContextPath; desired=$InitialState.desiredSerenaContext.content; original=$InitialState.serenaContextContent; intended=$manifest.intendedResources['codex-file-tools.yml']; acl=$originalSerenaContextAcl.Sddl },
            [pscustomobject]@{ name='config.toml'; path=$InitialState.configPath; desired=$InitialState.desiredConfig.content; original=$rollbackConfigContent; intended=$manifest.intendedResources['config.toml']; acl=$originalConfigAcl.Sddl },
            [pscustomobject]@{ name='hooks.json'; path=$InitialState.hooksPath; desired=$InitialState.desiredHooks.content; original=$InitialState.hooksContent; intended=$manifest.intendedResources['hooks.json']; acl=$originalHooksAcl.Sddl }
        )) {
            if (-not $attempted.Contains([string]$resource.name)) { continue }
            try {
                $current = Read-Text -Path ([string]$resource.path)
                if ($current.Equals([string]$resource.original, [StringComparison]::Ordinal)) { continue }
                if (-not $current.Equals([string]$resource.desired, [StringComparison]::Ordinal)) { throw '检测到第三方内容，拒绝覆盖' }
                Write-AtomicText -Path ([string]$resource.path) -Content ([string]$resource.original) -ExpectedCurrentSha256 ([string]$resource.intended) -ExpectedCurrentSddl ([string]$resource.acl)
            } catch {
                $rollbackErrors.Add("$($resource.name): $($_.Exception.Message)")
                $recoveryRequired.Add([string]$resource.name)
            }
        }

        if ($attempted.Contains('environment:SERENA_HOME')) {
            try {
                $currentEnvironment = Get-SerenaEnvironmentState -ResolvedCodexHome $ResolvedCodexHome
                if ([string]$currentEnvironment.value -ceq 'D:\Codex\.serena') {
                    if (Test-IsLiveCodexHome -ResolvedCodexHome $ResolvedCodexHome) {
                        Set-SerenaEnvironmentValue -ResolvedCodexHome $ResolvedCodexHome -Value ([string]$InitialState.environmentState.value) -ValueKind ([string]$InitialState.environmentState.valueKind) -ExpectedValue 'D:\Codex\.serena' -ExpectedValueKind 'String'
                    } else {
                        Write-AtomicText -Path ([string]$InitialState.environmentState.fixturePath) -Content ([string]$InitialState.environmentState.fixtureContent) -ExpectedCurrentSha256 ([string]$currentEnvironment.fixtureSha256) -ExpectedCurrentSddl ([string]$currentEnvironment.fixtureSddl)
                    }
                } elseif ([string]$currentEnvironment.value -cne [string]$InitialState.environmentState.value) { throw '检测到第三方 User 环境，拒绝覆盖' }
            } catch {
                $rollbackErrors.Add("environment:SERENA_HOME: $($_.Exception.Message)")
                $recoveryRequired.Add('environment:SERENA_HOME')
            }
        }

        $managedRollbackStates = @(Get-OrderedManagedHookItems -Items @($InitialState.managedFileStates | Where-Object { $attempted.Contains("managed:$($_.liveRelativePath)") }) -Direction Restore)
        foreach ($fileState in $managedRollbackStates) {
            try {
                $current = Get-CodexHookCapabilityFileSnapshot -Path ([string]$fileState.targetPath) -CapabilityRoot $InitialState.hookDirectory -AllowedExactPaths $managedTargetPaths -Name "post-commit rollback $($fileState.liveRelativePath)"
                if ($fileState.targetExists) {
                    $backupKey = ([string]$fileState.liveRelativePath).Replace('/', '\')
                    $backup = $manifest.originalHashes.managedHooks[$backupKey]
                    if ([string]$current.sha256 -ceq [string]$fileState.targetRawSha256 -and [string]$current.sddl -ceq [string]$backup.sddl) { continue }
                    if ([string]$current.sha256 -cne [string]$fileState.sourceRawSha256) { throw '检测到第三方 managed 版本，拒绝覆盖' }
                    [byte[]]$backupBytes = [IO.File]::ReadAllBytes([string]$backup.backupPath)
                    Set-CodexHookAtomicFileBytesWithCapability -Path ([string]$fileState.targetPath) -Bytes $backupBytes -ExpectedExists $true -ExpectedSha256 ([string]$fileState.sourceRawSha256) -AfterSha256 ([string]$backup.sha256) -CapabilityRoot $InitialState.hookDirectory -AllowedExactPaths $managedTargetPaths -Scope "post-commit rollback $($fileState.liveRelativePath)" -AfterRename {
                        param($publishedLease, $publishedPath)
                        Set-AclOwnerAndGroupFromSddl -Path $publishedPath -Sddl ([string]$backup.sddl)
                        $currentSddl = [string]$publishedLease.GetSecurityDescriptorSddl()
                        if ($currentSddl -cne [string]$backup.sddl) { $publishedLease.SetSecurityDescriptorSddl($currentSddl, [string]$backup.sddl) }
                        if ([string]$publishedLease.GetSecurityDescriptorSddl() -cne [string]$backup.sddl) { throw 'post-commit managed rollback ACL same-handle postcheck 失败' }
                    }
                } elseif ($current.exists) {
                    if ([string]$current.sha256 -cne [string]$fileState.sourceRawSha256) { throw '检测到第三方 managed 版本，拒绝覆盖' }
                    Remove-CodexHookCapabilityFile -Path ([string]$fileState.targetPath) -ExpectedSha256 ([string]$fileState.sourceRawSha256) -CapabilityRoot $InitialState.hookDirectory -AllowedExactPaths $managedTargetPaths -Scope "post-commit rollback $($fileState.liveRelativePath)"
                }
            } catch {
                $rollbackErrors.Add("managed:$($fileState.liveRelativePath): $($_.Exception.Message)")
                $recoveryRequired.Add("managed:$($fileState.liveRelativePath)")
            }
        }
        $managedDirectories = @($createdManagedDirectories.Keys | Sort-Object Length -Descending)
        foreach ($directory in $managedDirectories) {
            if ($directory.Equals($InitialState.hookDirectory, [StringComparison]::OrdinalIgnoreCase)) { continue }
            try {
                Invoke-FixtureCreatedDirectoryCleanupReplace -TargetParent $directory
                $expectedDirectory = $createdManagedDirectories[$directory]
                $deleteGuard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::AcquireForEmptyDelete($InitialState.hookDirectory, $directory)
                try {
                    if (
                        [string]$deleteGuard.VolumeSerialNumber -cne [string]$expectedDirectory.volumeSerialNumber -or
                        [string]$deleteGuard.FileIndex -cne [string]$expectedDirectory.fileIndex
                    ) {
                        throw '本次创建目录 identity 漂移，拒绝删除替代目录。'
                    }
                    $deleteGuard.DeleteEmptyDirectory()
                } finally {
                    $deleteGuard.Dispose()
                }
            } catch {
                $rollbackErrors.Add("managed-directory:${directory}: $($_.Exception.Message)")
                $recoveryRequired.Add("managed-directory:$directory")
            }
        }

        if (@($manifest.retiredResources).Count -gt 0) {
            $rollbackErrors.Add("retired resources are irreversible and were not recreated: $(@($manifest.retiredResources) -join ',')")
        }

        $manifest.status = if ($rollbackErrors.Count -eq 0) { 'rolled-back' } else { 'unsafe-partial' }
        $manifest.error = $postCommitFailure.Exception.Message
        $manifest.recoveryRequired = $recoveryRequired.ToArray()
        if ($rollbackErrors.Count -gt 0) { $manifest.rollbackErrors = $rollbackErrors.ToArray() }
        Write-Manifest -Path $snapshot.manifestPath -Manifest $manifest
        if ($rollbackErrors.Count -gt 0) { throw "post-commit 修复失败且回滚不完整：$($rollbackErrors -join '; ')" }
        throw $postCommitFailure
    }
}

function Resolve-RestoreEvidencePath {
    param(
        [string]$ResolvedCodexHome,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value) -or -not [IO.Path]::IsPathFullyQualified($Value)) {
        throw 'Restore 必须提供绝对 EvidencePath'
    }
    $evidenceRoot = (Resolve-CodexHostHookEvidenceScope -ResolvedCodexHome $ResolvedCodexHome).remediationRoot.TrimEnd('\')
    $resolvedEvidence = [IO.Path]::GetFullPath($Value).TrimEnd('\')
    if (-not [string]::Equals([IO.Path]::GetDirectoryName($resolvedEvidence), $evidenceRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'EvidencePath 必须是当前 CodexHome 固定 evidence root 的直接子目录'
    }
    Assert-NoReparsePath -Path $evidenceRoot -RequireLeaf | Out-Null
    Assert-NoReparsePath -Path $resolvedEvidence -RequireLeaf | Out-Null
    $manifestPath = Join-Path $resolvedEvidence 'manifest.json'
    Assert-NoReparsePath -Path $manifestPath -RequireLeaf | Out-Null
    [pscustomobject]@{ path = $resolvedEvidence; manifestPath = $manifestPath }
}

function Get-RestoreResourceState {
    param(
        [string]$CurrentSha256,
        [AllowNull()][string]$DeployedSha256,
        [AllowNull()][string]$BeforeSha256
    )

    if ($null -ne $BeforeSha256 -and $CurrentSha256 -ceq $BeforeSha256) { return 'before' }
    if ($null -ne $DeployedSha256 -and $CurrentSha256 -ceq $DeployedSha256) { return 'deployed' }
    'third'
}

function Initialize-RestoreFixtureTestSeam {
    param([string]$ResolvedCodexHome)

    $requested = $env:CODEX_HOST_HOOK_TEST_RESTORE_INTERRUPT_AFTER
    if (-not [string]::IsNullOrWhiteSpace($requested)) {
        if (Test-IsLiveCodexHome -ResolvedCodexHome $ResolvedCodexHome) { throw 'Restore fixture seam 禁止用于 live CodexHome' }
        if ($requested -cne '*' -and ($requested.Length -gt 512 -or $requested -match '[\x00-\x1f]')) { throw 'Restore fixture seam action identity 非法' }
        $script:FixtureRestoreInterruptAfter = $requested
    }
    $finalDrift = $env:CODEX_HOST_HOOK_TEST_RESTORE_FINAL_DRIFT
    if (-not [string]::IsNullOrWhiteSpace($finalDrift)) {
        if (Test-IsLiveCodexHome -ResolvedCodexHome $ResolvedCodexHome) { throw 'Restore final drift fixture seam 禁止用于 live CodexHome' }
        if ($finalDrift -cne 'hooks.json') { throw 'Restore final drift fixture seam 值非法' }
        $script:FixtureRestoreFinalDrift = $finalDrift
    }
    $manifestCas = $env:CODEX_HOST_HOOK_TEST_RESTORE_MANIFEST_CAS_REPLACE
    if (-not [string]::IsNullOrWhiteSpace($manifestCas)) {
        if (Test-IsLiveCodexHome -ResolvedCodexHome $ResolvedCodexHome) { throw 'Restore manifest CAS fixture seam 禁止用于 live CodexHome' }
        if ($manifestCas -cne '1') { throw 'Restore manifest CAS fixture seam 值非法' }
        $script:FixtureRestoreManifestCasReplace = $true
    }
    $backupRace = $env:CODEX_HOST_HOOK_TEST_RESTORE_BACKUP_AFTER_SNAPSHOT
    if (-not [string]::IsNullOrWhiteSpace($backupRace)) {
        if (Test-IsLiveCodexHome -ResolvedCodexHome $ResolvedCodexHome) { throw 'Restore backup snapshot fixture seam 禁止用于 live CodexHome' }
        if ($backupRace -cne 'hooks.json') { throw 'Restore backup snapshot fixture seam 值非法' }
        $script:FixtureRestoreBackupAfterSnapshot = $backupRace
    }
    $aclReplace = $env:CODEX_HOST_HOOK_TEST_RESTORE_ACL_REPLACE
    if (-not [string]::IsNullOrWhiteSpace($aclReplace)) {
        if (Test-IsLiveCodexHome -ResolvedCodexHome $ResolvedCodexHome) { throw 'Restore ACL replacement fixture seam 禁止用于 live CodexHome' }
        $replace = $aclReplace | ConvertFrom-Json
        if ((@($replace.PSObject.Properties.Name) -join ',') -cne 'targetPath,parkedPath,externalPath') { throw 'Restore ACL replacement fixture schema 非法' }
        $targetPath = [IO.Path]::GetFullPath([string]$replace.targetPath)
        $parkedPath = [IO.Path]::GetFullPath([string]$replace.parkedPath)
        $externalPath = [IO.Path]::GetFullPath([string]$replace.externalPath)
        $hookRoot = [IO.Path]::GetFullPath((Join-Path $ResolvedCodexHome 'hooks')).TrimEnd('\')
        $fixtureRoot = [IO.Directory]::GetParent([IO.Directory]::GetParent($ResolvedCodexHome).FullName).FullName
        if (
            -not $targetPath.StartsWith("$hookRoot\", [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([IO.Path]::GetDirectoryName($parkedPath), $hookRoot, [StringComparison]::OrdinalIgnoreCase) -or
            -not $externalPath.StartsWith("$fixtureRoot\", [StringComparison]::OrdinalIgnoreCase) -or
            $externalPath.StartsWith("$ResolvedCodexHome\", [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $targetPath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $externalPath -PathType Leaf) -or
            (Test-Path -LiteralPath $parkedPath)
        ) { throw 'Restore ACL replacement fixture capability 非法' }
        foreach ($path in @($targetPath,$externalPath)) { Assert-NoReparsePath -Path $path -RequireLeaf | Out-Null }
        $script:FixtureRestoreAclReplace = [pscustomobject]@{ targetPath=$targetPath; parkedPath=$parkedPath; externalPath=$externalPath }
    }
    foreach ($fixture in @(
        [pscustomobject]@{ environmentName='CODEX_HOST_HOOK_TEST_RESTORE_CONTENT_PARENT_REPLACE'; scriptName='FixtureRestoreContentParentReplace'; targetKind='content-parent' },
        [pscustomobject]@{ environmentName='CODEX_HOST_HOOK_TEST_RESTORE_MANIFEST_ACL_REPLACE'; scriptName='FixtureRestoreManifestAclReplace'; targetKind='manifest-acl' }
    )) {
        $raw = [Environment]::GetEnvironmentVariable([string]$fixture.environmentName)
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        if (Test-IsLiveCodexHome -ResolvedCodexHome $ResolvedCodexHome) { throw "$($fixture.targetKind) fixture seam 禁止用于 live CodexHome" }
        $replace = $raw | ConvertFrom-Json
        if ((@($replace.PSObject.Properties.Name) -join ',') -cne 'targetPath,parkedPath,externalPath') { throw "$($fixture.targetKind) fixture schema 非法" }
        $targetPath = [IO.Path]::GetFullPath([string]$replace.targetPath)
        $parkedPath = [IO.Path]::GetFullPath([string]$replace.parkedPath)
        $externalPath = [IO.Path]::GetFullPath([string]$replace.externalPath)
        $fixtureRoot = [IO.Directory]::GetParent([IO.Directory]::GetParent($ResolvedCodexHome).FullName).FullName
        if (
            -not $targetPath.StartsWith("$fixtureRoot\", [StringComparison]::OrdinalIgnoreCase) -or
            -not $parkedPath.StartsWith("$fixtureRoot\", [StringComparison]::OrdinalIgnoreCase) -or
            -not $externalPath.StartsWith("$fixtureRoot\", [StringComparison]::OrdinalIgnoreCase) -or
            $externalPath.StartsWith("$ResolvedCodexHome\", [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $targetPath) -or
            -not (Test-Path -LiteralPath $externalPath) -or
            (Test-Path -LiteralPath $parkedPath)
        ) { throw "$($fixture.targetKind) fixture capability 非法" }
        foreach ($path in @($targetPath,$externalPath)) { Assert-NoReparsePath -Path $path -RequireLeaf | Out-Null }
        Set-Variable -Scope Script -Name ([string]$fixture.scriptName) -Value ([pscustomobject]@{ targetPath=$targetPath; parkedPath=$parkedPath; externalPath=$externalPath })
    }
}

function Invoke-FixtureRestorePathReplace {
    param(
        [AllowNull()][object]$Fixture,
        [string]$TargetPath
    )
    if ($null -eq $Fixture -or -not [string]::Equals([string]$Fixture.targetPath, [IO.Path]::GetFullPath($TargetPath), [StringComparison]::OrdinalIgnoreCase)) { return }
    Move-Item -LiteralPath ([string]$Fixture.targetPath) -Destination ([string]$Fixture.parkedPath)
    if (Test-Path -LiteralPath ([string]$Fixture.externalPath) -PathType Container) {
        New-FixtureJunction -JunctionPath ([string]$Fixture.targetPath) -TargetPath ([string]$Fixture.externalPath)
    } else {
        New-Item -ItemType HardLink -Path ([string]$Fixture.targetPath) -Target ([string]$Fixture.externalPath) | Out-Null
    }
}

function Complete-RestoreAction {
    param(
        [string]$Name,
        [Collections.Generic.List[string]]$Progress,
        [System.Collections.IDictionary]$Manifest,
        [object]$ManifestState
    )

    if ($Progress.Contains($Name)) { return }
    $Progress.Add($Name)
    $Manifest.restoreProgress = $Progress.ToArray()
    Write-RestoreManifestCas -Manifest $Manifest -State $ManifestState
    if ($script:FixtureRestoreInterruptAfter -ceq '*' -or $script:FixtureRestoreInterruptAfter -ceq $Name) {
        $script:FixtureRestoreInterruptAfter = $null
        throw "fixture-only restore interrupted after persisted action：$Name"
    }
}

function Assert-RestoreManifestSchema {
    param([System.Collections.IDictionary]$Manifest)

    [string[]]$expected = @(
        'schemaVersion','runId','createdAtUtc','codexHome','status','originalHashes','preservedHookTree',
        'intendedResources','attemptedResources','committedResources','retiredResources','aclTargets',
        'aclAppliedStates','concurrentReplace','rollbackConcurrentReplaces','rollbackErrors','error',
        'restoreContractSha256','restoreClaimSha256','restoreProgress','restoreBlocked','recoveryRequired',
        'restoredAtUtc','completedAtUtc'
    )
    $keys = @($Manifest.Keys)
    if ($keys.Count -ne $expected.Count) { throw 'Restore manifest schema 属性数量非法' }
    $allowed = [Collections.Generic.HashSet[string]]::new($expected, [StringComparer]::Ordinal)
    foreach ($key in $keys) { if ($key -isnot [string] -or -not $allowed.Remove([string]$key)) { throw "Restore manifest schema 包含未知或重复属性：$key" } }
    if ($allowed.Count -ne 0) { throw "Restore manifest schema 缺少属性：$(@($allowed) -join ',')" }
    if ($Manifest.schemaVersion -isnot [long] -and $Manifest.schemaVersion -isnot [int]) { throw 'Restore manifest schemaVersion 类型非法' }
    foreach ($name in @('attemptedResources','committedResources','retiredResources','aclTargets','rollbackConcurrentReplaces','rollbackErrors','restoreProgress','restoreBlocked','recoveryRequired')) {
        if ($null -eq $Manifest[$name] -or $Manifest[$name] -isnot [System.Collections.IList]) { throw "Restore manifest $name 必须是 array" }
    }
    if ([string]$Manifest.status -notin @('completed','restoring','restore-blocked','restored')) { throw 'Restore evidence 状态不可恢复' }
}

function Write-RestoreManifestCas {
    param(
        [System.Collections.IDictionary]$Manifest,
        [object]$State
    )

    [byte[]]$bytes = [Text.UTF8Encoding]::new($false).GetBytes(((ConvertTo-Json -InputObject $Manifest -Depth 40) + "`n"))
    $afterSha = Get-CodexHookBytesSha256 -Bytes $bytes
    if ($script:FixtureRestoreManifestCasReplace) {
        $script:FixtureRestoreManifestCasReplace = $false
        [IO.File]::AppendAllText([string]$State.path, " `n", [Text.UTF8Encoding]::new($false))
    }
    Set-CodexHookAtomicFileBytesWithCapability `
        -Path ([string]$State.path) `
        -Bytes $bytes `
        -ExpectedExists $true `
        -ExpectedSha256 ([string]$State.sha256) `
        -ExpectedIdentity ([string[]]$State.identity) `
        -AfterSha256 $afterSha `
        -CapabilityRoot ([string]$State.capabilityRoot) `
        -AllowedExactPaths @([string]$State.path) `
        -Scope 'Restore manifest CAS' `
        -AfterRename {
            param($publishedLease, $publishedPath)
            Invoke-FixtureRestorePathReplace -Fixture $script:FixtureRestoreManifestAclReplace -TargetPath $publishedPath
            Set-ProtectedAclCurrentUserOwner -Path $publishedPath
            $currentSddl = [string]$publishedLease.GetSecurityDescriptorSddl()
            $desiredSddl = Get-ProtectedAclSddl -CurrentSddl $currentSddl -IsDirectory $false
            if ($currentSddl -cne $desiredSddl) { $publishedLease.SetSecurityDescriptorSddl($currentSddl, $desiredSddl) }
            if ([string]$publishedLease.GetSecurityDescriptorSddl() -cne $desiredSddl) { throw 'Restore manifest ACL same-handle postcheck 失败' }
        }
    $State.sha256 = $afterSha
    $publishedSnapshot = Get-CodexHookCapabilityFileSnapshot -Path ([string]$State.path) -CapabilityRoot ([string]$State.capabilityRoot) -AllowedExactPaths @([string]$State.path) -Name 'Restore manifest published identity'
    $State.identity = @($publishedSnapshot.identity)
}

function New-RestoreAclTargetLease {
    param(
        [string]$ResolvedCodexHome,
        [string]$Path
    )

    $fullPath = Assert-RestoreAclAuthorizedPath -ResolvedCodexHome $ResolvedCodexHome -Path $Path
    $capabilityRoot = [IO.Directory]::GetParent($ResolvedCodexHome).FullName
    $parentPath = [IO.Path]::GetDirectoryName($fullPath)
    $guard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire($capabilityRoot, $parentPath, $false)
    try {
        $lease = $guard.AcquireAclTargetLease($fullPath)
        [pscustomobject]@{
            path = $fullPath
            guard = $guard
            lease = $lease
            currentSddl = [string]$lease.GetSecurityDescriptorSddl()
        }
    } catch {
        $guard.Dispose()
        throw
    }
}

function Close-RestoreAclTargetLease {
    param([AllowNull()][object]$Record)
    if ($null -eq $Record) { return }
    try { if ($null -ne $Record.lease) { $Record.lease.Dispose() } } finally { $Record.guard.Dispose() }
}

function Get-RestoreAclTargetSddl {
    param(
        [string]$ResolvedCodexHome,
        [object]$Item
    )

    if ($Item.PSObject.Properties.Name -ccontains 'aclLease' -and $null -ne $Item.aclLease) {
        return [string]$Item.aclLease.lease.GetSecurityDescriptorSddl()
    }
    $record = New-RestoreAclTargetLease -ResolvedCodexHome $ResolvedCodexHome -Path ([string]$Item.path)
    try { [string]$record.lease.GetSecurityDescriptorSddl() } finally { Close-RestoreAclTargetLease -Record $record }
}

function Assert-RestoreFreshPostcheck {
    param(
        [string]$ResolvedCodexHome,
        [object[]]$Items,
        [object]$Authority
    )

    foreach ($item in @($Items)) {
        switch ([string]$item.kind) {
            'content' {
                $snapshot = Get-CodexHookHandleBoundFileSnapshot -Path ([string]$item.path) -Name "Restore postcheck $($item.name)" -AllowedExactPaths @([string]$item.path)
                if (-not $snapshot.probe.safeToRead -or (Get-CodexHookBytesSha256 -Bytes ([byte[]]$snapshot.bytes)) -cne [string]$item.beforeSha) { throw "Restore postcheck 漂移：$($item.name)" }
                if ([string]$snapshot.sddl -cne [string]$item.beforeSddl) { throw "Restore postcheck ACL 漂移：$($item.name)" }
            }
            'environment' {
                $current = Get-SerenaEnvironmentState -ResolvedCodexHome $ResolvedCodexHome
                if ([string]$current.value -cne [string]$item.beforeValue -or [string]$current.valueKind -cne [string]$item.beforeKind) { throw "Restore postcheck 漂移：$($item.name)" }
            }
            'managed' {
                $snapshot = Get-CodexHookHandleBoundFileSnapshot -Path ([string]$item.path) -Name "Restore postcheck $($item.name)" -AllowedExactPaths @([string]$item.path)
                if ([bool]$item.before.existed) {
                    if (-not $snapshot.probe.safeToRead -or (Get-CodexHookBytesSha256 -Bytes ([byte[]]$snapshot.bytes)) -cne [string]$item.before.sha256) { throw "Restore postcheck 漂移：$($item.name)" }
                    if ([string]$snapshot.sddl -cne [string]$item.before.sddl) { throw "Restore postcheck ACL 漂移：$($item.name)" }
                } elseif ($snapshot.probe.exists) { throw "Restore postcheck 漂移：$($item.name)" }
            }
            'acl' {
                if ((Get-RestoreAclTargetSddl -ResolvedCodexHome $ResolvedCodexHome -Item $item) -cne [string]$item.beforeSddl) { throw "Restore postcheck 漂移：$($item.name)" }
            }
            default { throw "Restore postcheck 未知 action kind：$($item.kind)" }
        }
    }
    $hookDirectory = Join-Path $ResolvedCodexHome 'hooks'
    $hookTree = @(Get-Item -LiteralPath $hookDirectory -Force) + @(Get-ChildItem -LiteralPath $hookDirectory -Recurse -Force)
    $preserved = @(Get-PreservedHookTreeInventory -HookDirectory $hookDirectory -HookTree $hookTree)
    if (($preserved | ConvertTo-Json -Depth 8 -Compress) -cne (@($Authority.preservedHookTree) | ConvertTo-Json -Depth 8 -Compress)) { throw 'Restore postcheck preserved hook tree 漂移' }
}

function Assert-OrderedUniqueSubsequence {
    param([object[]]$Actual, [string[]]$Allowed, [string]$Name)

    $lastIndex = -1
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entryValue in @($Actual)) {
        if ($entryValue -isnot [string] -or -not $seen.Add([string]$entryValue)) { throw "$Name 包含非字符串或重复项" }
        $index = [Array]::IndexOf($Allowed, [string]$entryValue)
        if ($index -lt 0 -or $index -le $lastIndex) { throw "$Name 不是固定 profile 的有序子序列" }
        $lastIndex = $index
    }
}

function Assert-RestoreProgressPrefix {
    param(
        [object[]]$Actual,
        [object[]]$ActionOrder
    )

    if (@($Actual).Count -gt @($ActionOrder).Count) { throw 'restoreProgress 超出认证 actionOrder' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    for ($index = 0; $index -lt @($Actual).Count; $index++) {
        $entry = $Actual[$index]
        if ($entry -isnot [string] -or -not $seen.Add([string]$entry)) { throw 'restoreProgress 包含非字符串或重复项' }
        if ([string]$entry -cne [string]$ActionOrder[$index]) { throw "restoreProgress 不是认证 actionOrder 的严格前缀：index=$index expected=$($ActionOrder[$index]) actual=$entry" }
    }
}

function Assert-RestoreAclAuthorizedPath {
    param([string]$ResolvedCodexHome, [string]$Path)

    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $hooksPath = [IO.Path]::GetFullPath((Join-Path $ResolvedCodexHome 'hooks.json'))
    $hookRoot = [IO.Path]::GetFullPath((Join-Path $ResolvedCodexHome 'hooks')).TrimEnd('\')
    $contextPath = [IO.Path]::GetFullPath((Join-Path ([IO.Directory]::GetParent($ResolvedCodexHome).FullName) '.serena\contexts\codex-file-tools.yml'))
    if (-not ($full.Equals($hooksPath, [StringComparison]::OrdinalIgnoreCase) -or $full.Equals($contextPath, [StringComparison]::OrdinalIgnoreCase) -or $full.Equals($hookRoot, [StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith("$hookRoot\", [StringComparison]::OrdinalIgnoreCase))) {
        throw 'Restore ACL target 不属于固定 host profile'
    }
    Assert-NoReparsePath -Path $full | Out-Null
    $full
}

function Assert-RestoreContractClosure {
    param([string]$ResolvedCodexHome, [object]$Contract, [System.Collections.IDictionary]$AclBefore)

    $state = $Contract.immutableState
    Assert-CodexHookExactProperties $state @('runId','codexHome','originalHashes','preservedHookTree','intendedResources','committedResources','retiredResources','aclTargets','aclAppliedStates') 'host hook restore immutable state'
    $repairManagedIds = @(Get-OrderedManagedHookItems -Items @($script:HostPreflightManifest.files) -Direction Repair | ForEach-Object { "managed:$($_.liveRelativePath)" })
    $restoreManagedIds = @(Get-OrderedManagedHookItems -Items @($script:HostPreflightManifest.files) -Direction Restore | ForEach-Object { "managed:$($_.liveRelativePath)" })
    [string[]]$allowedCommitted = @('codex-file-tools.yml','config.toml') + $repairManagedIds + @('environment:SERENA_HOME','hooks.json')
    Assert-OrderedUniqueSubsequence -Actual @($state.committedResources) -Allowed $allowedCommitted -Name 'committedResources'
    if (@($state.committedResources) -ccontains 'hooks.json' -and @($state.committedResources)[-1] -cne 'hooks.json') { throw 'committedResources 的 hooks.json 必须最后' }
    if (@($state.retiredResources).Count -ne 0) {
        throw 'Restore contract 不得包含已退役 Hook；删除不可逆'
    }
    $aclSeen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @($state.aclTargets)) {
        if ($path -isnot [string] -or -not $aclSeen.Add([string]$path)) { throw 'ACL targets 包含非字符串或重复项' }
        [void](Assert-RestoreAclAuthorizedPath -ResolvedCodexHome $ResolvedCodexHome -Path ([string]$path))
        if ($state.aclAppliedStates.PSObject.Properties.Name -cnotcontains [string]$path) { throw 'ACL target 缺少 deployed SDDL binding' }
    }
    if (@($state.aclAppliedStates.PSObject.Properties.Name).Count -ne @($state.aclTargets).Count) { throw 'ACL target/applied closure 不精确' }
    $intendedManagedNames = @($state.intendedResources.managedHooks.PSObject.Properties.Name)
    $expectedManagedNames = @($script:HostPreflightManifest.files | ForEach-Object { ([string]$_.liveRelativePath).Replace('/', '\') })
    if ((($intendedManagedNames | Sort-Object) -join "`n") -cne (($expectedManagedNames | Sort-Object) -join "`n")) {
        throw 'Restore managed intended raw hash closure 不精确'
    }
    foreach ($file in @($script:HostPreflightManifest.files)) {
        $managedKey = ([string]$file.liveRelativePath).Replace('/', '\')
        $intendedProperty = $state.intendedResources.managedHooks.PSObject.Properties[$managedKey]
        if ($null -eq $intendedProperty -or [string]$intendedProperty.Value -cnotmatch '^[0-9a-f]{64}$') {
            throw "Restore managed deployed raw hash 缺失或非法：$($file.liveRelativePath)"
        }
        $key = ([string]$file.liveRelativePath).Replace('/', '\')
        $beforeProperty = $state.originalHashes.managedHooks.PSObject.Properties[$key]
        if ($null -eq $beforeProperty) { throw "Restore managed before state 缺失：$key" }
        $before = $beforeProperty.Value
        Assert-CodexHookExactProperties $before @('existed','sha256','sddl','backupPath') "Restore managed before state $key"
        if ([bool]$before.existed -and ([string]::IsNullOrWhiteSpace([string]$before.sha256) -or [string]::IsNullOrWhiteSpace([string]$before.sddl) -or [string]::IsNullOrWhiteSpace([string]$before.backupPath))) { throw "Restore managed before state 未绑定 bytes/ACL：$key" }
        if (-not [bool]$before.existed -and ($null -ne $before.sha256 -or $null -ne $before.sddl -or $null -ne $before.backupPath)) { throw "Restore managed missing before state 非空：$key" }
    }
    $expectedActions = [Collections.Generic.List[string]]::new()
    if (@($state.committedResources) -ccontains 'hooks.json') { $expectedActions.Add('hooks.json') }
    if (@($state.committedResources) -ccontains 'environment:SERENA_HOME') { $expectedActions.Add('environment:SERENA_HOME') }
    foreach ($id in $restoreManagedIds) { if (@($state.committedResources) -ccontains $id) { $expectedActions.Add($id) } }
    foreach ($id in @('config.toml','codex-file-tools.yml')) { if (@($state.committedResources) -ccontains $id) { $expectedActions.Add($id) } }
    $hookRootPath = [IO.Path]::GetFullPath((Join-Path $ResolvedCodexHome 'hooks')).TrimEnd('\')
    $aclActionOrdinal = 0
    $orderedAclActions = @($state.aclTargets | ForEach-Object {
        $path = [string]$_
        [pscustomobject]@{ path=$path; depth=@([IO.Path]::GetFullPath($path).TrimEnd('\') -split '[\\/]').Count; ordinal=$aclActionOrdinal++ }
    } | Sort-Object depth,ordinal)
    foreach ($aclAction in @($orderedAclActions | Where-Object { [IO.Path]::GetFullPath([string]$_.path).TrimEnd('\').Equals($hookRootPath, [StringComparison]::OrdinalIgnoreCase) })) { if ($AclBefore.Contains($aclAction.path)) { $expectedActions.Add("acl:$($aclAction.path)") } }
    foreach ($aclAction in @($orderedAclActions | Where-Object { -not [IO.Path]::GetFullPath([string]$_.path).TrimEnd('\').Equals($hookRootPath, [StringComparison]::OrdinalIgnoreCase) })) { if ($AclBefore.Contains($aclAction.path)) { $expectedActions.Add("acl:$($aclAction.path)") } }
    if ((@($Contract.actionOrder) -join "`n") -cne ($expectedActions.ToArray() -join "`n")) { throw 'restore contract actionOrder 与固定 profile closure 不一致' }
}

function Assert-RestoreEvidenceExcludesRetiredProjectTrust {
    param([Parameter(Mandatory)][string]$EvidencePath)

    $configEvidencePath = Join-Path $EvidencePath 'config.toml'
    $snapshot = Get-RequiredCapabilitySnapshot -Path $configEvidencePath -CapabilityRoot $EvidencePath -Name 'Restore config evidence snapshot'
    $content = Convert-StrictUtf8SnapshotText -Snapshot $snapshot -Name 'Restore config evidence'
    try {
        $sanitized = Remove-RetiredProjectTrustFromContent `
            -Content $content `
            -RetiredProjectTrusts @($script:HostPreflightManifest.retiredProjectTrusts)
    } catch {
        throw "Restore config evidence 无法结构化验证退役 project trust：$($_.Exception.Message)"
    }
    if (-not $content.Equals($sanitized, [StringComparison]::Ordinal)) {
        throw 'Restore config evidence 含退役 project trust；拒绝恢复。请先通过 retired project snapshot sanitizer 清理历史快照。'
    }
}

function Invoke-EvidenceRestore {
    param(
        [string]$ResolvedCodexHome,
        [string]$EvidencePath
    )

    $evidence = Resolve-RestoreEvidencePath -ResolvedCodexHome $ResolvedCodexHome -Value $EvidencePath
    $manifestSnapshot = Get-RequiredCapabilitySnapshot -Path $evidence.manifestPath -CapabilityRoot ([string]$evidence.path) -Name 'Restore manifest snapshot'
    $manifestText = Convert-StrictUtf8SnapshotText -Snapshot $manifestSnapshot -Name 'Restore manifest'
    Assert-CodexHookStrictJsonText -JsonText $manifestText
    $manifest = $manifestText | ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String
    Assert-RestoreManifestSchema -Manifest $manifest
    $manifestState = [pscustomobject]@{ path=$evidence.manifestPath; capabilityRoot=[string]$evidence.path; sha256=[string]$manifestSnapshot.sha256; identity=@($manifestSnapshot.identity) }
    if ([int]$manifest.schemaVersion -ne 1 -or [string]$manifest.codexHome -cne $ResolvedCodexHome) {
        throw 'Restore evidence 未绑定当前 CodexHome'
    }
    $restoreContract = Read-HostHookRestoreContract -ResolvedCodexHome $ResolvedCodexHome -Evidence $evidence -Manifest $manifest
    Assert-RestoreEvidenceExcludesRetiredProjectTrust -EvidencePath ([string]$evidence.path)
    $authority = $restoreContract.immutableState
    $hookDirectory = Join-Path $ResolvedCodexHome 'hooks'
    $managedTargetPaths = @($script:HostPreflightManifest.files | ForEach-Object { Join-Path $hookDirectory ([string]$_.liveRelativePath) })
    $aclBeforePath = Join-Path $evidence.path 'acl-before.json'
    $aclBeforeSnapshot = Get-RequiredCapabilitySnapshot -Path $aclBeforePath -CapabilityRoot ([string]$evidence.path) -Name 'Restore ACL backup snapshot'
    if (([string]$aclBeforeSnapshot.sha256).ToLowerInvariant() -cne ([string]$authority.originalHashes.'acl-before.json').ToLowerInvariant()) { throw 'Restore ACL backup hash 漂移' }
    $aclBeforeText = Convert-StrictUtf8SnapshotText -Snapshot $aclBeforeSnapshot -Name 'Restore ACL backup'
    Assert-CodexHookStrictJsonText -JsonText $aclBeforeText
    $aclBefore = $aclBeforeText | ConvertFrom-Json -AsHashtable -Depth 16 -DateKind String
    Assert-RestoreContractClosure -ResolvedCodexHome $ResolvedCodexHome -Contract $restoreContract -AclBefore $aclBefore
    if (-not $manifest.Contains('restoreProgress')) { $manifest.restoreProgress = @() }
    Assert-RestoreProgressPrefix -Actual @($manifest.restoreProgress) -ActionOrder @($restoreContract.actionOrder)
    if ([string]$manifest.status -ceq 'completed' -and @($manifest.restoreProgress).Count -ne 0) { throw 'completed evidence 不得带 restoreProgress' }
    if ([string]$manifest.status -ceq 'restored' -and (@($manifest.restoreProgress) -join "`n") -cne (@($restoreContract.actionOrder) -join "`n")) { throw 'restored evidence 必须完成全部认证 actionOrder' }
    $progress = [Collections.Generic.List[string]]::new()
    foreach ($entry in @($manifest.restoreProgress)) { $progress.Add([string]$entry) }
    $preflight = [Collections.Generic.List[object]]::new()

    $contentSpecs = @(
        [pscustomobject]@{ name='hooks.json'; path=(Join-Path $ResolvedCodexHome 'hooks.json'); backup=(Join-Path $evidence.path 'hooks.json'); capabilityRoot=$ResolvedCodexHome },
        [pscustomobject]@{ name='config.toml'; path=(Join-Path $ResolvedCodexHome 'config.toml'); backup=(Join-Path $evidence.path 'config.toml'); capabilityRoot=$ResolvedCodexHome },
        [pscustomobject]@{ name='codex-file-tools.yml'; path=(Join-Path ([IO.Directory]::GetParent($ResolvedCodexHome).FullName) '.serena\contexts\codex-file-tools.yml'); backup=(Join-Path $evidence.path 'codex-file-tools.yml'); capabilityRoot=([IO.Directory]::GetParent($ResolvedCodexHome).FullName) }
    )
    foreach ($spec in $contentSpecs) {
        if (@($authority.committedResources) -cnotcontains $spec.name) { continue }
        $backupSnapshot = Get-RequiredCapabilitySnapshot -Path $spec.backup -CapabilityRoot ([string]$evidence.path) -Name "Restore backup snapshot $($spec.name)"
        $beforeSha = ([string]$backupSnapshot.sha256).ToLowerInvariant()
        if ($beforeSha -cne ([string]$authority.originalHashes.$($spec.name)).ToLowerInvariant()) { throw "Restore backup hash 漂移：$($spec.name)" }
        $currentSnapshot = Get-CodexHookCapabilityFileSnapshot -Path $spec.path -CapabilityRoot ([string]$spec.capabilityRoot) -AllowedExactPaths @([string]$spec.path) -Name "Restore content preflight $($spec.name)"
        if (-not $currentSnapshot.exists -or [string]$currentSnapshot.state -cne 'regular-file') { throw "Restore content target 非普通文件：$($spec.name)" }
        $currentSha = ([string]$currentSnapshot.sha256).ToLowerInvariant()
        $deployedSha = ([string]$authority.intendedResources.$($spec.name)).ToLowerInvariant()
        [byte[]]$backupBytes = [byte[]]$backupSnapshot.bytes
        if ($script:FixtureRestoreBackupAfterSnapshot -ceq $spec.name) {
            $script:FixtureRestoreBackupAfterSnapshot = $null
            [IO.File]::AppendAllText($spec.backup, " `n", [Text.UTF8Encoding]::new($false))
        }
        $beforeSddl = [string]$aclBefore[[string]$spec.path]
        $contentState = Get-RestoreResourceState $currentSha $deployedSha $beforeSha
        if ($contentState -ceq 'before' -and [string]$currentSnapshot.sddl -cne $beforeSddl) { $contentState = 'third' }
        $preflight.Add([pscustomobject]@{ kind='content'; name=$spec.name; path=$spec.path; capabilityRoot=[string]$spec.capabilityRoot; backupBytes=$backupBytes; currentSha=$currentSha; currentIdentity=@($currentSnapshot.identity); deployedSha=$deployedSha; beforeSha=$beforeSha; beforeSddl=$beforeSddl; state=$contentState })
    }

    if (@($authority.committedResources) -ccontains 'environment:SERENA_HOME') {
        $environment = Get-SerenaEnvironmentState -ResolvedCodexHome $ResolvedCodexHome
        $beforeValue = [string]$authority.originalHashes.environment.SERENA_HOME.value
        $beforeKind = [string]$authority.originalHashes.environment.SERENA_HOME.kind
        $environmentBackupSha256 = [string]$authority.originalHashes.environment.SERENA_HOME.sha256
        $environmentBackupPath = if ([string]::IsNullOrWhiteSpace($environmentBackupSha256)) { $null } else { Join-Path $evidence.path 'user-environment.json' }
        if (-not [string]::IsNullOrWhiteSpace($environmentBackupPath)) {
            $environmentBackupSnapshot = Get-RequiredCapabilitySnapshot -Path $environmentBackupPath -CapabilityRoot ([string]$evidence.path) -Name 'Restore User 环境 backup snapshot'
            if (([string]$environmentBackupSnapshot.sha256).ToLowerInvariant() -cne $environmentBackupSha256.ToLowerInvariant()) { throw 'Restore User 环境 backup hash 漂移' }
        }
        $environmentState = if ([string]$environment.value -ceq $beforeValue -and [string]$environment.valueKind -ceq $beforeKind) { 'before' } elseif ([string]$environment.value -ceq 'D:\Codex\.serena' -and [string]$environment.valueKind -ceq 'String') { 'deployed' } else { 'third' }
        $environmentBackupText = if ($null -eq $environmentBackupPath) { $null } else { Convert-StrictUtf8SnapshotText -Snapshot $environmentBackupSnapshot -Name 'Restore User 环境 backup' }
        $preflight.Add([pscustomobject]@{ kind='environment'; name='environment:SERENA_HOME'; state=$environmentState; beforeValue=$beforeValue; beforeKind=$beforeKind; current=$environment; backupText=$environmentBackupText; backupSha256=$environmentBackupSha256 })
    }

    foreach ($file in @($script:HostPreflightManifest.files)) {
        $name = "managed:$($file.liveRelativePath)"
        if (@($authority.committedResources) -cnotcontains $name) { continue }
        $targetPath = Join-Path $hookDirectory ([string]$file.liveRelativePath)
        $beforeKey = ([string]$file.liveRelativePath).Replace('/', '\')
        $before = $authority.originalHashes.managedHooks.$beforeKey
        $deployedProperty = $authority.intendedResources.managedHooks.PSObject.Properties[$beforeKey]
        if ($null -eq $deployedProperty -or [string]$deployedProperty.Value -cnotmatch '^[0-9a-f]{64}$') { throw "Restore managed deployed raw hash 缺失或非法：$($file.liveRelativePath)" }
        $deployedSha = ([string]$deployedProperty.Value).ToLowerInvariant()
        $managedBackupPath = Join-Path (Join-Path $evidence.path 'managed-hooks-before') $beforeKey
        $managedBackupSnapshot = if ([bool]$before.existed) { Get-RequiredCapabilitySnapshot -Path $managedBackupPath -CapabilityRoot ([string]$evidence.path) -Name "Restore managed backup snapshot $name" } else { $null }
        [byte[]]$managedBackupBytes = if ([bool]$before.existed) { [byte[]]$managedBackupSnapshot.bytes } else { $null }
        if ([bool]$before.existed -and (Get-CodexHookBytesSha256 -Bytes $managedBackupBytes) -cne [string]$before.sha256) { throw "Restore managed backup hash 漂移：$name" }
        $snapshot = Get-CodexHookCapabilityFileSnapshot -Path $targetPath -CapabilityRoot $hookDirectory -AllowedExactPaths $managedTargetPaths -Name "restore preflight $name"
        $state = if ([bool]$before.existed) {
            if ($snapshot.exists -and [string]$snapshot.sha256 -ceq [string]$before.sha256 -and [string]$snapshot.sddl -ceq [string]$before.sddl) { 'before' } elseif ($snapshot.exists -and [string]$snapshot.sha256 -ceq $deployedSha) { 'deployed' } else { 'third' }
        } else {
            if (-not $snapshot.exists) { 'before' } elseif ([string]$snapshot.sha256 -ceq $deployedSha) { 'deployed' } else { 'third' }
        }
        $preflight.Add([pscustomobject]@{ kind='managed'; name=$name; liveRelativePath=[string]$file.liveRelativePath; path=$targetPath; state=$state; before=$before; backupBytes=$managedBackupBytes; deployedSha=$deployedSha })
    }

    $aclOrdinal = 0
    foreach ($path in @($authority.aclTargets)) {
        if (-not $aclBefore.Contains([string]$path)) { continue }
        $aclReadLease = New-RestoreAclTargetLease -ResolvedCodexHome $ResolvedCodexHome -Path ([string]$path)
        try { $currentSddl = [string]$aclReadLease.currentSddl } finally { Close-RestoreAclTargetLease -Record $aclReadLease }
        $beforeSddl = [string]$aclBefore[[string]$path]
        $deployedSddl = [string]$authority.aclAppliedStates.$path
        $state = if ($currentSddl -ceq $beforeSddl) { 'before' } elseif ($currentSddl -ceq $deployedSddl) { 'deployed' } else { 'third' }
        $preflight.Add([pscustomobject]@{ kind='acl'; name="acl:$path"; path=[string]$path; beforeSddl=$beforeSddl; deployedSddl=$deployedSddl; state=$state; depth=@([IO.Path]::GetFullPath([string]$path).TrimEnd('\') -split '[\\/]').Count; ordinal=$aclOrdinal++; aclLease=$null })
    }

    $third = @($preflight | Where-Object { $_.state -ceq 'third' })
    if ($third.Count -gt 0) {
        $manifest.status = 'restore-blocked'
        $manifest.restoreBlocked = @($third | ForEach-Object { [string]$_.name })
        $manifest.recoveryRequired = @($manifest.restoreBlocked)
        Write-RestoreManifestCas -Manifest $manifest -State $manifestState
        throw "Restore 预检发现第三版本：$(@($manifest.restoreBlocked) -join ',')"
    }
    if ([string]$manifest.status -ceq 'restored') {
        Assert-RestoreFreshPostcheck -ResolvedCodexHome $ResolvedCodexHome -Items @($preflight) -Authority $authority
        return [pscustomobject]@{ schemaVersion=1; mode='Restore'; ok=$true; changed=$false; driftCount=0; checks=@(); registrationProjection=@(); evidencePath=$evidence.path }
    }

    $manifest.status = 'restoring'
    $manifest.restoreBlocked = @()
    $manifest.recoveryRequired = @()
    $manifest.restoreProgress = $progress.ToArray()
    Write-RestoreManifestCas -Manifest $manifest -State $manifestState
    foreach ($item in @($preflight | Where-Object { $_.kind -ceq 'content' -and $_.name -ceq 'hooks.json' })) {
        if ($item.state -ceq 'deployed') {
            Set-CodexHookAtomicFileBytesWithCapability `
                -Path ([string]$item.path) `
                -Bytes ([byte[]]$item.backupBytes) `
                -ExpectedExists $true `
                -ExpectedSha256 ([string]$item.deployedSha) `
                -ExpectedIdentity ([string[]]$item.currentIdentity) `
                -AfterSha256 ([string]$item.beforeSha) `
                -CapabilityRoot ([string]$item.capabilityRoot) `
                -AllowedExactPaths @([string]$item.path) `
                -Scope "Restore content $($item.name)" `
                -BeforeMove { param($targetPath) Invoke-FixtureRestorePathReplace -Fixture $script:FixtureRestoreContentParentReplace -TargetPath (Split-Path -Parent $targetPath) } `
                -AfterRename {
                    param($publishedLease, $publishedPath)
                    Set-AclOwnerAndGroupFromSddl -Path $publishedPath -Sddl ([string]$item.beforeSddl)
                    $currentSddl = [string]$publishedLease.GetSecurityDescriptorSddl()
                    if ($currentSddl -cne [string]$item.beforeSddl) { $publishedLease.SetSecurityDescriptorSddl($currentSddl, [string]$item.beforeSddl) }
                    if ([string]$publishedLease.GetSecurityDescriptorSddl() -cne [string]$item.beforeSddl) { throw "Restore content ACL same-handle postcheck 失败：$($item.name)" }
                }
        }
        Complete-RestoreAction -Name $item.name -Progress $progress -Manifest $manifest -ManifestState $manifestState
    }
    foreach ($item in @($preflight | Where-Object { $_.kind -ceq 'environment' })) {
        if ($item.state -ceq 'deployed') {
            if ($null -ne $item.backupText) {
                Write-AtomicText -Path ([string]$item.current.fixturePath) -Content $item.backupText -ExpectedCurrentSha256 ([string]$item.current.fixtureSha256) -ExpectedCurrentSddl ([string]$item.current.fixtureSddl)
            } else {
                Set-SerenaEnvironmentValue -ResolvedCodexHome $ResolvedCodexHome -Value $item.beforeValue -ValueKind $item.beforeKind -ExpectedValue 'D:\Codex\.serena' -ExpectedValueKind 'String'
            }
        }
        Complete-RestoreAction -Name $item.name -Progress $progress -Manifest $manifest -ManifestState $manifestState
    }
    $managedRestoreItems = @(Get-OrderedManagedHookItems -Items @($preflight | Where-Object { $_.kind -ceq 'managed' }) -Direction Restore)
    foreach ($item in $managedRestoreItems) {
        if ($item.state -ceq 'deployed') {
            if ([bool]$item.before.existed) {
                Set-CodexHookAtomicFileBytesWithCapability -Path $item.path -Bytes ([byte[]]$item.backupBytes) -ExpectedExists $true -ExpectedSha256 $item.deployedSha -AfterSha256 ([string]$item.before.sha256) -CapabilityRoot $hookDirectory -AllowedExactPaths $managedTargetPaths -Scope "restore $($item.name)" -AfterRename {
                    param($publishedLease, $publishedPath)
                    Set-AclOwnerAndGroupFromSddl -Path $publishedPath -Sddl ([string]$item.before.sddl)
                    $currentSddl = [string]$publishedLease.GetSecurityDescriptorSddl()
                    if ($currentSddl -cne [string]$item.before.sddl) { $publishedLease.SetSecurityDescriptorSddl($currentSddl, [string]$item.before.sddl) }
                    if ([string]$publishedLease.GetSecurityDescriptorSddl() -cne [string]$item.before.sddl) { throw "Restore managed ACL same-handle postcheck 失败：$($item.name)" }
                }
            } else {
                Remove-CodexHookCapabilityFile -Path $item.path -ExpectedSha256 $item.deployedSha -CapabilityRoot $hookDirectory -AllowedExactPaths $managedTargetPaths -Scope "restore $($item.name)"
            }
        }
        Complete-RestoreAction -Name $item.name -Progress $progress -Manifest $manifest -ManifestState $manifestState
    }
    foreach ($item in @($preflight | Where-Object { $_.kind -ceq 'content' -and $_.name -cne 'hooks.json' })) {
        if ($item.state -ceq 'deployed') {
            Set-CodexHookAtomicFileBytesWithCapability `
                -Path ([string]$item.path) `
                -Bytes ([byte[]]$item.backupBytes) `
                -ExpectedExists $true `
                -ExpectedSha256 ([string]$item.deployedSha) `
                -ExpectedIdentity ([string[]]$item.currentIdentity) `
                -AfterSha256 ([string]$item.beforeSha) `
                -CapabilityRoot ([string]$item.capabilityRoot) `
                -AllowedExactPaths @([string]$item.path) `
                -Scope "Restore content $($item.name)" `
                -BeforeMove { param($targetPath) Invoke-FixtureRestorePathReplace -Fixture $script:FixtureRestoreContentParentReplace -TargetPath (Split-Path -Parent $targetPath) } `
                -AfterRename {
                    param($publishedLease, $publishedPath)
                    Set-AclOwnerAndGroupFromSddl -Path $publishedPath -Sddl ([string]$item.beforeSddl)
                    $currentSddl = [string]$publishedLease.GetSecurityDescriptorSddl()
                    if ($currentSddl -cne [string]$item.beforeSddl) { $publishedLease.SetSecurityDescriptorSddl($currentSddl, [string]$item.beforeSddl) }
                    if ([string]$publishedLease.GetSecurityDescriptorSddl() -cne [string]$item.beforeSddl) { throw "Restore content ACL same-handle postcheck 失败：$($item.name)" }
                }
        }
        Complete-RestoreAction -Name $item.name -Progress $progress -Manifest $manifest -ManifestState $manifestState
    }
    foreach ($item in @($preflight | Where-Object {
        $_.kind -ceq 'acl' -and [IO.Path]::GetFullPath([string]$_.path).TrimEnd('\').Equals([IO.Path]::GetFullPath($hookDirectory).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
    })) {
        if ($item.state -ceq 'deployed') {
            $record = New-RestoreAclTargetLease -ResolvedCodexHome $ResolvedCodexHome -Path ([string]$item.path)
            try {
                Set-AclOwnerAndGroupFromSddl -Path ([string]$item.path) -Sddl ([string]$item.beforeSddl)
                $currentSddl = [string]$record.lease.GetSecurityDescriptorSddl()
                $record.lease.SetSecurityDescriptorSddl($currentSddl, [string]$item.beforeSddl)
                if ([string]$record.lease.GetSecurityDescriptorSddl() -cne [string]$item.beforeSddl) { throw "Restore parent ACL same-handle postcheck 失败：$($item.name)" }
                $item.state = 'before'
            } finally { Close-RestoreAclTargetLease -Record $record }
        }
        Complete-RestoreAction -Name $item.name -Progress $progress -Manifest $manifest -ManifestState $manifestState
    }
    $heldAclRecords = [Collections.Generic.List[object]]::new()
    try {
        $aclRecheckThird = [Collections.Generic.List[object]]::new()
        foreach ($item in @($preflight | Where-Object { $_.kind -ceq 'acl' } | Sort-Object depth,ordinal)) {
            $record = New-RestoreAclTargetLease -ResolvedCodexHome $ResolvedCodexHome -Path ([string]$item.path)
            $heldAclRecords.Add($record)
            $item.aclLease = $record
            $currentSddl = [string]$record.currentSddl
            $item.state = if ($currentSddl -ceq [string]$item.beforeSddl) { 'before' } elseif ($currentSddl -ceq [string]$item.deployedSddl) { 'deployed' } else { 'third' }
            if ($item.state -ceq 'third') { $aclRecheckThird.Add($item) }
        }
        if ($null -ne $script:FixtureRestoreAclReplace) {
            $replace = $script:FixtureRestoreAclReplace
            $script:FixtureRestoreAclReplace = $null
            $targetAction = "acl:$($replace.targetPath)"
            try {
                Move-Item -LiteralPath ([string]$replace.targetPath) -Destination ([string]$replace.parkedPath)
                New-Item -ItemType HardLink -Path ([string]$replace.targetPath) -Target ([string]$replace.externalPath) | Out-Null
                throw 'fixture-only ACL replacement unexpectedly succeeded while leases were held'
            } catch {
                $manifest.status = 'restore-blocked'
                $manifest.restoreBlocked = @($targetAction)
                $manifest.recoveryRequired = @($targetAction)
                Write-RestoreManifestCas -Manifest $manifest -State $manifestState
                throw "fixture-only Restore ACL replacement blocked：$($_.Exception.Message)"
            }
        }
        if ($aclRecheckThird.Count -gt 0) {
            $manifest.status = 'restore-blocked'
            $manifest.restoreBlocked = @($aclRecheckThird | ForEach-Object { [string]$_.name })
            $manifest.recoveryRequired = @($manifest.restoreBlocked)
            Write-RestoreManifestCas -Manifest $manifest -State $manifestState
            throw "Restore ACL lease 复核发现第三版本：$(@($manifest.restoreBlocked) -join ',')"
        }

        foreach ($item in @($preflight | Where-Object { $_.kind -ceq 'acl' } | Sort-Object depth,ordinal)) {
            if ($item.state -ceq 'deployed') {
                Set-AclOwnerAndGroupFromSddl -Path ([string]$item.path) -Sddl ([string]$item.beforeSddl)
                $currentSddl = [string]$item.aclLease.lease.GetSecurityDescriptorSddl()
                $item.aclLease.lease.SetSecurityDescriptorSddl($currentSddl, [string]$item.beforeSddl)
                if ([string]$item.aclLease.lease.GetSecurityDescriptorSddl() -cne [string]$item.beforeSddl) { throw "Restore ACL same-handle postcheck 失败：$($item.name)" }
            }
            Complete-RestoreAction -Name $item.name -Progress $progress -Manifest $manifest -ManifestState $manifestState
        }

        if ($script:FixtureRestoreFinalDrift -ceq 'hooks.json') {
        $script:FixtureRestoreFinalDrift = $null
        [IO.File]::AppendAllText((Join-Path $ResolvedCodexHome 'hooks.json'), "`n", [Text.UTF8Encoding]::new($false))
    }
    try {
        Assert-RestoreFreshPostcheck -ResolvedCodexHome $ResolvedCodexHome -Items @($preflight) -Authority $authority
    } catch {
        $manifest.status = 'restore-blocked'
        $manifest.restoreBlocked = @('terminal-postcheck')
        $manifest.recoveryRequired = @('terminal-postcheck')
        Write-RestoreManifestCas -Manifest $manifest -State $manifestState
        throw
    }
    $manifest.status = 'restored'
    $manifest.restoredAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    $manifest.restoreProgress = $progress.ToArray()
    Write-RestoreManifestCas -Manifest $manifest -State $manifestState
        [pscustomobject]@{ schemaVersion=1; mode='Restore'; ok=$true; changed=$true; driftCount=0; checks=@(); registrationProjection=@(); evidencePath=$evidence.path }
    } finally {
        for ($index = $heldAclRecords.Count - 1; $index -ge 0; $index--) { Close-RestoreAclTargetLease -Record $heldAclRecords[$index] }
        foreach ($item in @($preflight | Where-Object { $_.kind -ceq 'acl' })) { $item.aclLease = $null }
    }
}

try {
    $resolvedHome = Resolve-CodexHome -Value $CodexHome
    if ($Mode -eq "Check") {
        if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) { throw 'Check 不接受 EvidencePath' }
        $state = Get-ReconciliationState -ResolvedCodexHome $resolvedHome
        $result = New-Result -ResultMode "Check" -State $state -Changed $false -EvidencePath $null
    } else {
        Assert-RepairHomeAuthorized -ResolvedCodexHome $resolvedHome
        if ($Mode -eq 'Repair') {
            if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) { throw 'Repair 不接受 EvidencePath' }
            Initialize-FixtureTestSeams -ResolvedCodexHome $resolvedHome
        } else {
            Initialize-RestoreFixtureTestSeam -ResolvedCodexHome $resolvedHome
        }
        $mutex = [System.Threading.Mutex]::new($false, (Get-RepairMutexName -ResolvedCodexHome $resolvedHome))
        $lockTaken = $false
        try {
            try {
                $lockTaken = $mutex.WaitOne(5000)
            } catch [System.Threading.AbandonedMutexException] {
                $lockTaken = $true
            }
            if (-not $lockTaken) {
                throw "另一个 Repair 正在处理同一 CodexHome"
            }

            if ($Mode -eq 'Repair') {
                $state = Get-ReconciliationState -ResolvedCodexHome $resolvedHome
                $result = Invoke-Repair -ResolvedCodexHome $resolvedHome -InitialState $state
            } else {
                $result = Invoke-EvidenceRestore -ResolvedCodexHome $resolvedHome -EvidencePath $EvidencePath
            }
        } finally {
            if ($lockTaken) {
                $mutex.ReleaseMutex()
            }
            $mutex.Dispose()
        }
    }

    if ($Json) {
        ConvertTo-Json -InputObject $result -Depth 10 -Compress
    } else {
        $result
    }
} catch {
    if ($Json) {
        [pscustomobject]@{
            schemaVersion = 1
            mode = $Mode
            ok = $false
            changed = $null
            driftCount = $null
            checks = @()
            evidencePath = $script:CurrentEvidencePath
            error = [pscustomobject]@{
                code = "reconciliation-failed"
                message = "检查或修复失败；JSON 输出已脱敏，请在受保护 evidence 中查看详细诊断（如有）"
            }
        } | ConvertTo-Json -Depth 6 -Compress | Write-Output
        throw "reconciliation-failed"
    }
    throw
}
