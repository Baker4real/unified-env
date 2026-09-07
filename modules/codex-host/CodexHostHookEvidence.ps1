# Evidence snapshot lifecycle for the host hook reconciler.
#
# The production script remains the stable adapter.  This module owns the
# transaction precondition snapshot so evidence creation, protected writes,
# and the manifest closure stay local to codex-host.

function Resolve-CodexHostHookEvidenceScope {
    param(
        [string]$ResolvedCodexHome,
        [switch]$ForceProduction
    )

    $liveHome = [IO.Path]::GetFullPath('D:\Codex\.codex').TrimEnd('\')
    if ($ForceProduction -and [string]::IsNullOrWhiteSpace($ResolvedCodexHome)) {
        $ResolvedCodexHome = $liveHome
    }
    if ([string]::IsNullOrWhiteSpace($ResolvedCodexHome)) {
        throw 'Resolve-CodexHostHookEvidenceScope 需要 ResolvedCodexHome 或 -ForceProduction'
    }
    $resolved = [IO.Path]::GetFullPath($ResolvedCodexHome).TrimEnd('\')
    $isLive = $resolved.Equals($liveHome, [StringComparison]::OrdinalIgnoreCase)
    $useProduction = $ForceProduction -or $isLive
    if ($useProduction) {
        $runEvidenceRoot = [IO.Path]::GetFullPath('D:\agents\run-evidence')
        return [pscustomobject]@{
            runEvidenceRoot = $runEvidenceRoot
            remediationRoot = [IO.Path]::GetFullPath((Join-Path $runEvidenceRoot 'host-hook-remediation'))
            capabilityRoot = $runEvidenceRoot
            isFixture = $false
            isLive = $isLive
        }
    }

    $runEvidenceRoot = [IO.Path]::GetFullPath((Join-Path $resolved 'run-evidence'))
    [pscustomobject]@{
        runEvidenceRoot = $runEvidenceRoot
        remediationRoot = [IO.Path]::GetFullPath((Join-Path $runEvidenceRoot 'host-hook-remediation'))
        capabilityRoot = $resolved
        isFixture = $true
        isLive = $false
    }
}

function New-CodexHostHookEvidenceSnapshot {
    param(
        [Parameter(Mandatory)][string]$ResolvedCodexHome,
        [Parameter(Mandatory)][object]$State
    )

    $scope = Resolve-CodexHostHookEvidenceScope -ResolvedCodexHome $ResolvedCodexHome
    $runEvidenceRoot = $scope.runEvidenceRoot
    $capabilityRoot = $scope.capabilityRoot
    $evidenceRoot = $scope.remediationRoot
    [void](New-CodexHookCapabilityDirectory -Path $runEvidenceRoot -CapabilityRoot $capabilityRoot -Name 'run evidence root')
    Assert-NoReparsePath -Path $runEvidenceRoot -RequireLeaf | Out-Null

    [void](New-CodexHookCapabilityDirectory -Path $evidenceRoot -CapabilityRoot $capabilityRoot -Name 'host hook evidence root')
    Assert-NoReparsePath -Path $evidenceRoot -RequireLeaf | Out-Null
    Set-ProtectedAclWithCapability -Path $evidenceRoot -CapabilityRoot $capabilityRoot

    $runId = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmss.fffZ") + "-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    $evidencePath = Join-Path $evidenceRoot $runId
    [void](New-CodexHookCapabilityDirectory -Path $evidencePath -CapabilityRoot $capabilityRoot -Name 'host hook evidence run' -RequireMissing)
    $script:CurrentEvidencePath = $evidencePath
    Set-ProtectedAclWithCapability -Path $evidencePath -CapabilityRoot $capabilityRoot
    $hooksEvidencePath = Join-Path $evidencePath "hooks.json"
    $serenaContextEvidencePath = Join-Path $evidencePath "codex-file-tools.yml"
    $livePreconditionHashes = [ordered]@{
        "hooks.json" = Get-TextSha256 -Content ([string]$State.hooksContent)
        "codex-file-tools.yml" = Get-TextSha256 -Content ([string]$State.serenaContextContent)
    }
    [void](Write-NewOnlyProtectedBytes -Path $hooksEvidencePath -Bytes ([Text.UTF8Encoding]::new($false).GetBytes([string]$State.hooksContent)) -CapabilityRoot $evidencePath)
    [void](Write-NewOnlyProtectedBytes -Path $serenaContextEvidencePath -Bytes ([Text.UTF8Encoding]::new($false).GetBytes([string]$State.serenaContextContent)) -CapabilityRoot $evidencePath)

    $managedEvidence = Join-Path $evidencePath 'managed-hooks-before'
    [void](New-CodexHookCapabilityDirectory -Path $managedEvidence -CapabilityRoot $evidencePath -Name 'managed evidence root' -RequireMissing)
    Set-ProtectedAclWithCapability -Path $managedEvidence -CapabilityRoot $evidencePath
    $managedBefore = [ordered]@{}
    foreach ($fileState in @($State.managedFileStates)) {
        $backupRelativePath = ([string]$fileState.liveRelativePath).Replace('/', '\')
        $backupPath = Join-Path $managedEvidence $backupRelativePath
        $backupParent = Split-Path -Parent $backupPath
        if ($backupParent -ine $managedEvidence) {
            [void](New-CodexHookCapabilityDirectory -Path $backupParent -CapabilityRoot $managedEvidence -Name 'managed evidence parent')
            Set-ProtectedAclWithCapability -Path $backupParent -CapabilityRoot $managedEvidence
        }
        if ($fileState.targetExists) {
            [void](Write-NewOnlyProtectedBytes -Path $backupPath -Bytes ([IO.File]::ReadAllBytes([string]$fileState.targetPath)) -CapabilityRoot $managedEvidence)
        }
        $managedBefore[$backupRelativePath] = [ordered]@{
            existed = [bool]$fileState.targetExists
            sha256 = $fileState.targetRawSha256
            sddl = if ($fileState.targetExists) { (Get-Acl -LiteralPath ([string]$fileState.targetPath)).Sddl } else { $null }
            backupPath = if ($fileState.targetExists) { $backupPath } else { $null }
        }
    }

    $aclBefore = [ordered]@{}
    foreach ($path in @($State.hooksPath, $State.serenaContextPath) + @($State.hookTreePaths)) {
        $aclBefore[$path] = (Get-Acl -LiteralPath $path).Sddl
    }
    $aclBeforePath = Join-Path $evidencePath "acl-before.json"
    [void](Write-NewOnlyProtectedBytes -Path $aclBeforePath -Bytes ([Text.UTF8Encoding]::new($false).GetBytes((($aclBefore | ConvertTo-Json -Depth 4) + "`n"))) -CapabilityRoot $evidencePath)

    $environmentEvidencePath = $null
    $environmentEvidenceSha256 = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$State.environmentState.fixturePath)) {
        $environmentEvidencePath = Join-Path $evidencePath 'user-environment.json'
        $environmentEvidenceSha256 = Write-NewOnlyProtectedBytes -Path $environmentEvidencePath -Bytes ([IO.File]::ReadAllBytes([string]$State.environmentState.fixturePath)) -CapabilityRoot $evidencePath
    }

    $manifest = [ordered]@{
        schemaVersion = 1
        runId = $runId
        createdAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        codexHome = $ResolvedCodexHome
        status = "prepared"
        originalHashes = [ordered]@{
            "hooks.json" = Get-Sha256 -Path $hooksEvidencePath
            "codex-file-tools.yml" = Get-Sha256 -Path $serenaContextEvidencePath
            "acl-before.json" = Get-Sha256 -Path $aclBeforePath
            managedHooks = $managedBefore
            environment = [ordered]@{ SERENA_HOME = [ordered]@{ value = $State.environmentState.value; kind = [string]$State.environmentState.valueKind; backupPath = $environmentEvidencePath; sha256 = $environmentEvidenceSha256 } }
        }
        preservedHookTree = @($State.preservedHookTree)
        intendedResources = [ordered]@{
            "codex-file-tools.yml" = if ($State.desiredSerenaContext.changed) { Get-TextSha256 -Content $State.desiredSerenaContext.content } else { $null }
            "hooks.json" = if ($State.desiredHooks.changed) { Get-TextSha256 -Content $State.desiredHooks.content } else { $null }
            managedHooks = [ordered]@{}
            environment = [ordered]@{ SERENA_HOME = 'D:\Codex\.serena' }
        }
        attemptedResources = @()
        committedResources = @()
        retiredResources = @()
        aclTargets = @()
        aclAppliedStates = [ordered]@{}
        concurrentReplace = $null
        rollbackConcurrentReplaces = @()
        rollbackErrors = @()
        error = $null
        restoreContractSha256 = $null
        restoreClaimSha256 = $null
        restoreProgress = @()
        restoreBlocked = @()
        recoveryRequired = @()
        restoredAtUtc = $null
        completedAtUtc = $null
    }
    foreach ($fileState in @($State.managedFileStates)) {
        $managedHookKey = ([string]$fileState.liveRelativePath).Replace('/', '\')
        $manifest.intendedResources.managedHooks[$managedHookKey] = [string]$fileState.sourceRawSha256
    }
    $manifestPath = Join-Path $evidencePath "manifest.json"
    Write-Manifest -Path $manifestPath -Manifest $manifest

    [pscustomobject]@{
        path = $evidencePath
        manifestPath = $manifestPath
        manifest = $manifest
        livePreconditionHashes = $livePreconditionHashes
    }
}
