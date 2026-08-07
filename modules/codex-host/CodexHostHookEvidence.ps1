# Evidence snapshot lifecycle for the host hook reconciler.
#
# The production script remains the stable adapter.  This module owns the
# transaction precondition snapshot so evidence creation, protected writes,
# and the manifest closure stay local to codex-host.

function New-CodexHostHookEvidenceSnapshot {
    param(
        [Parameter(Mandatory)][string]$ResolvedCodexHome,
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][string[]]$RetiredProjectTrusts
    )

    $runEvidenceRoot = Join-Path $ResolvedCodexHome "run-evidence"
    [void](New-CodexHookCapabilityDirectory -Path $runEvidenceRoot -CapabilityRoot $ResolvedCodexHome -Name 'run evidence root')
    Assert-NoReparsePath -Path $runEvidenceRoot -RequireLeaf | Out-Null

    $evidenceRoot = Join-Path $runEvidenceRoot "host-hook-remediation"
    [void](New-CodexHookCapabilityDirectory -Path $evidenceRoot -CapabilityRoot $ResolvedCodexHome -Name 'host hook evidence root')
    Assert-NoReparsePath -Path $evidenceRoot -RequireLeaf | Out-Null
    Set-ProtectedAclWithCapability -Path $evidenceRoot -CapabilityRoot $ResolvedCodexHome

    $runId = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmss.fffZ") + "-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    $evidencePath = Join-Path $evidenceRoot $runId
    [void](New-CodexHookCapabilityDirectory -Path $evidencePath -CapabilityRoot $ResolvedCodexHome -Name 'host hook evidence run' -RequireMissing)
    $script:CurrentEvidencePath = $evidencePath
    Set-ProtectedAclWithCapability -Path $evidencePath -CapabilityRoot $ResolvedCodexHome
    $configEvidencePath = Join-Path $evidencePath "config.toml"
    $hooksEvidencePath = Join-Path $evidencePath "hooks.json"
    $serenaContextEvidencePath = Join-Path $evidencePath "codex-file-tools.yml"
    # Evidence may omit retired trust blocks, while live CAS must bind the
    # untouched state captured before this transaction.
    $livePreconditionHashes = [ordered]@{
        "config.toml" = Get-TextSha256 -Content ([string]$State.configContent)
        "hooks.json" = Get-TextSha256 -Content ([string]$State.hooksContent)
        "codex-file-tools.yml" = Get-TextSha256 -Content ([string]$State.serenaContextContent)
    }
    $sanitizedConfigEvidence = Remove-RetiredProjectTrustFromContent `
        -Content ([string]$State.configContent) `
        -RetiredProjectTrusts $RetiredProjectTrusts
    [void](Write-NewOnlyProtectedBytes -Path $configEvidencePath -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($sanitizedConfigEvidence)) -CapabilityRoot $evidencePath)
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
    foreach ($path in @($State.configPath, $State.hooksPath, $State.serenaContextPath) + @($State.hookTreePaths)) {
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
            "config.toml" = Get-Sha256 -Path $configEvidencePath
            "hooks.json" = Get-Sha256 -Path $hooksEvidencePath
            "codex-file-tools.yml" = Get-Sha256 -Path $serenaContextEvidencePath
            "acl-before.json" = Get-Sha256 -Path $aclBeforePath
            managedHooks = $managedBefore
            environment = [ordered]@{ SERENA_HOME = [ordered]@{ value = $State.environmentState.value; kind = [string]$State.environmentState.valueKind; backupPath = $environmentEvidencePath; sha256 = $environmentEvidenceSha256 } }
        }
        preservedHookTree = @($State.preservedHookTree)
        intendedResources = [ordered]@{
            "codex-file-tools.yml" = if ($State.desiredSerenaContext.changed) { Get-TextSha256 -Content $State.desiredSerenaContext.content } else { $null }
            "config.toml" = if ($State.desiredConfig.changed) { Get-TextSha256 -Content $State.desiredConfig.content } else { $null }
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
