[CmdletBinding(DefaultParameterSetName = 'Fixture')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Fixture')][string]$PlanPath,
    [switch]$Apply,
    [Parameter(ParameterSetName = 'Fixture')]
    [Parameter(Mandatory, ParameterSetName = 'ProductionRegistrationRepair')]
    [Parameter(Mandatory, ParameterSetName = 'ProductionFull')]
    [string]$ApprovedScope,
    [Parameter(Mandatory, ParameterSetName = 'Fixture')][string]$EvidenceRoot,
    [Parameter(ParameterSetName = 'Fixture')][scriptblock]$EnvironmentReadValue,
    [Parameter(ParameterSetName = 'Fixture')][scriptblock]$EnvironmentWriteValue,
    [Parameter(ParameterSetName = 'Fixture')][ValidateSet('none', 'before-wrapper', 'registry-postcheck')][string]$FaultInjection = 'none',
    [Parameter(Mandatory, ParameterSetName = 'ProductionRegistrationRepair')][switch]$ProductionRegistrationRepair,
    [Parameter(Mandatory, ParameterSetName = 'ProductionFull')][switch]$ProductionFull,
    [Parameter(ParameterSetName = 'ProductionFull')][string]$ApprovedGenerationId,
    [Parameter(ParameterSetName = 'ProductionFull')][string]$ApprovedPlanSha256
)

if ($PSCmdlet.ParameterSetName -in @('ProductionRegistrationRepair', 'ProductionFull')) {
    [pscustomobject][ordered]@{
        applied = $false
        refusalReason = 'superseded-by-host-hook-reconciler'
    }
    return
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\CodexHookPolicy.ps1')
. (Join-Path $PSScriptRoot 'lib\CodexHookProductionRegistrationRepair.ps1')
. (Join-Path $PSScriptRoot 'lib\CodexHookProductionFull.ps1')

if (-not $Apply) {
    [pscustomobject][ordered]@{ applied = $false; refusalReason = 'apply-switch-required' }
    return
}
if ($ApprovedScope -cne 'codex-hook-governance-2026-07-11') {
    [pscustomobject][ordered]@{ applied = $false; refusalReason = 'approved-scope-mismatch' }
    return
}

$planFullPath = Assert-CodexHookDPath -Value $PlanPath -Name 'PlanPath'
$evidenceRootPath = Assert-CodexHookFixturePath -Path $EvidenceRoot -Name 'EvidenceRoot'
$planSnapshot = Read-CodexHookSafeUtf8FileSnapshot -Path $planFullPath -Name 'deployment plan' -AllowedExactPaths @($planFullPath)
Assert-CodexHookStrictJsonText -JsonText $planSnapshot.text
$plan = $planSnapshot.text | ConvertFrom-Json -Depth 128 -DateKind String -ErrorAction Stop
[void](Assert-CodexHookDeploymentPlanFresh -Plan $plan)

$manifestPath = Assert-CodexHookDPath -Value ([string]$plan.sourceFacts.manifestPath) -Name 'plan manifestPath'
$manifestSnapshot = Read-CodexHookSafeUtf8FileSnapshot -Path $manifestPath -Name 'deployment manifest' -AllowedExactPaths @($manifestPath)
if ($manifestSnapshot.sha256 -cne $plan.manifestSha256 -or $manifestSnapshot.sha256 -cne $plan.sourceFacts.manifestSha256) {
    throw 'manifest final gate 失败：SHA-256 漂移。'
}
Assert-CodexHookStrictJsonText -JsonText $manifestSnapshot.text
$manifest = $manifestSnapshot.text | ConvertFrom-Json -Depth 128 -ErrorAction Stop
[void](Assert-CodexHookManifest -Manifest $manifest)

$sourceRoot = Assert-CodexHookFixturePath -Path ([string]$plan.sourceFacts.sourceRoot) -Name 'plan sourceRoot'
$codexHome = Assert-CodexHookFixturePath -Path ([string]$plan.liveFacts.codexHome) -Name 'plan codexHome'
$hooksRoot = [IO.Path]::GetFullPath((Join-Path $codexHome 'hooks'))
$registryPath = [IO.Path]::GetFullPath((Join-Path $codexHome 'hooks.json'))
$mappingIdentity = Get-CodexHookFixtureMappingIdentity -Manifest $manifest -SourceRoot $sourceRoot -CodexHome $codexHome
if ($mappingIdentity -cne $plan.sourceFacts.mappingIdentity -or $mappingIdentity -cne $plan.liveFacts.mappingIdentity) {
    throw 'target mapper final gate 失败。'
}
$lifecyclePaths = Get-CodexHookFixtureLifecyclePaths -MappingIdentity $mappingIdentity -GenerationId ([string]$plan.generationId)
foreach ($callerRoot in @(
    @{ Path = $sourceRoot; Name = 'sourceRoot' },
    @{ Path = $codexHome; Name = 'codexHome' },
    @{ Path = $evidenceRootPath; Name = 'EvidenceRoot' }
)) {
    if (Test-CodexHookPathWithin -Path ([string]$callerRoot.Path) -ParentPath ([string]$lifecyclePaths.lifecycleRoot)) {
        throw "$($callerRoot.Name) 不得位于固定 lifecycle state 根内。"
    }
}

$sourceFacts = [Collections.Generic.List[object]]::new()
$liveFacts = [Collections.Generic.List[object]]::new()
$gateSourceBytes = @{}
$gateTargetBytes = @{}
foreach ($file in @($manifest.files)) {
    $sourcePath = [IO.Path]::GetFullPath((Join-Path $sourceRoot ([string]$file.relativePath)))
    $targetPath = [IO.Path]::GetFullPath((Join-Path $hooksRoot ([string]$file.liveRelativePath)))
    if (-not (Test-CodexHookPathWithin -Path $sourcePath -ParentPath $sourceRoot) -or -not (Test-CodexHookPathWithin -Path $targetPath -ParentPath $hooksRoot)) {
        throw 'fixed mapper 产生越界路径。'
    }
    $sourceSnapshot = Get-CodexHookHandleBoundFileSnapshot -Path $sourcePath -Name 'gate source' -AllowedExactPaths @($sourcePath)
    $sourceSha = if ($sourceSnapshot.probe.safeToRead) { Get-CodexHookBytesSha256 -Bytes ([byte[]]$sourceSnapshot.bytes) } else { $null }
    if ($sourceSnapshot.probe.safeToRead) { $gateSourceBytes[[string]$file.relativePath] = [byte[]]$sourceSnapshot.bytes }
    $sourceFacts.Add([pscustomobject][ordered]@{
        relativePath = [string]$file.relativePath
        path = $sourcePath
        exists = $sourceSnapshot.probe.exists -eq $true
        probeState = [string]$sourceSnapshot.probe.state
        sha256 = $sourceSha
    })

    $targetSnapshot = Get-CodexHookHandleBoundFileSnapshot -Path $targetPath -Name 'gate target' -AllowedExactPaths @($targetPath)
    $targetSha = if ($targetSnapshot.probe.safeToRead) { Get-CodexHookBytesSha256 -Bytes ([byte[]]$targetSnapshot.bytes) } else { $null }
    if ($targetSnapshot.probe.safeToRead) { $gateTargetBytes[$targetPath] = [byte[]]$targetSnapshot.bytes }
    $liveFacts.Add([pscustomobject][ordered]@{
        liveRelativePath = [string]$file.liveRelativePath
        path = $targetPath
        exists = $targetSnapshot.probe.exists -eq $true
        probeState = [string]$targetSnapshot.probe.state
        sha256 = $targetSha
    })
}

$registrySnapshot = Read-CodexHookSafeUtf8FileSnapshot -Path $registryPath -Name 'gate registry' -AllowedExactPaths @($registryPath)
Assert-CodexHookStrictJsonText -JsonText $registrySnapshot.text
$registry = $registrySnapshot.text | ConvertFrom-Json -Depth 128 -ErrorAction Stop
try {
    $desiredRegistry = Merge-CodexHookRegistry -Manifest $manifest -LiveRegistry $registry -Mode ([string]$plan.mode)
} catch {
    throw 'registry ownership final gate 失败：ambiguous-or-drifted。'
}

$environmentFacts = [Collections.Generic.List[object]]::new()
if ($plan.mode -ceq 'full' -and @($manifest.environment).Count -gt 0) {
    if ($null -eq $EnvironmentReadValue -or $null -eq $EnvironmentWriteValue) {
        throw 'fixture apply 必须注入 environment memory adapter。'
    }
    foreach ($environment in @($manifest.environment)) {
        $environmentFacts.Add((Get-CodexHookEnvironmentValueFact `
            -Name ([string]$environment.name) `
            -Scope ([string]$environment.scope) `
            -ReadValue $EnvironmentReadValue `
            -Desired ([string]$environment.desired)))
    }
}

$inventory = [pscustomobject][ordered]@{
    targetProfile = 'codex-hook-fixture-v1'
    mappingIdentity = $mappingIdentity
    manifestPath = $manifestPath
    manifestSha256 = [string]$manifestSnapshot.sha256
    sourceRoot = $sourceRoot
    codexHome = $codexHome
    hooksRoot = $hooksRoot
    registryPath = $registryPath
    registryBeforeSha256 = [string]$registrySnapshot.sha256
    sourceFiles = [object[]]$sourceFacts.ToArray()
    liveFiles = [object[]]$liveFacts.ToArray()
    environmentFacts = [object[]]$environmentFacts.ToArray()
    blockers = @()
}
$derivedPlan = New-CodexHookDeploymentPlanDocument -Manifest $manifest -Inventory $inventory -DesiredRegistry $desiredRegistry -Mode ([string]$plan.mode)
if (-not $derivedPlan.applyEligible) {
    $codes = @($derivedPlan.sourceFacts.blockerReasonCodes)
    if ($codes -contains 'source-fact-mismatch') { throw 'source final gate 失败：SHA-256 漂移。' }
    throw "deployment final gate 失败：$($codes -join ',')"
}
if ($registrySnapshot.sha256 -cne $plan.registryBeforeSha256) {
    throw 'live registry final gate 失败：before SHA-256 漂移。'
}
if ($derivedPlan.registryAfterSha256 -cne $plan.registryAfterSha256) {
    throw 'registry deterministic merge final gate 失败。'
}
foreach ($propertyName in @('actions', 'environmentActions', 'postChecks')) {
    $plannedJson = $plan.$propertyName | ConvertTo-Json -Depth 100 -Compress
    $derivedJson = $derivedPlan.$propertyName | ConvertTo-Json -Depth 100 -Compress
    if ($plannedJson -cne $derivedJson) {
        throw "plan action contract final gate 失败：$propertyName"
    }
}

if ($null -eq $EnvironmentReadValue) { $EnvironmentReadValue = { param($Name, $Scope) return $null } }
if ($null -eq $EnvironmentWriteValue) { $EnvironmentWriteValue = { param($Name, $Scope, $Value) throw 'environment adapter 未授权' } }

$mutexName = Get-CodexHookFixtureDeploymentMutexName -MappingIdentity $mappingIdentity
$deploymentMutex = [Threading.Mutex]::new($false, $mutexName)
$mutexHeld = $false
try {
    $mutexHeld = $deploymentMutex.WaitOne(0)
    if (-not $mutexHeld) { throw 'deployment mutex busy。' }

    # The lifecycle mutex covers the final state gate, claim/status lifecycle, and every
    # fixture mutation. Restore uses this exact mapping-scoped mutex as well.
    foreach ($fact in @($sourceFacts)) {
        $current = Get-CodexHookFixtureFileSnapshot -Path ([string]$fact.path) -Name 'source critical recheck'
        Assert-CodexHookSnapshotExpectedState -Snapshot $current -ExpectedExists ([bool]$fact.exists) -ExpectedSha256 ([string]$fact.sha256) -Scope 'source critical recheck'
    }
    foreach ($fact in @($liveFacts)) {
        $current = Get-CodexHookFixtureFileSnapshot -Path ([string]$fact.path) -Name 'target critical recheck'
        Assert-CodexHookSnapshotExpectedState -Snapshot $current -ExpectedExists ([bool]$fact.exists) -ExpectedSha256 ([string]$fact.sha256) -Scope 'target critical recheck'
    }
    $registryCritical = Get-CodexHookFixtureFileSnapshot -Path $registryPath -Name 'registry critical recheck'
    Assert-CodexHookSnapshotExpectedState -Snapshot $registryCritical -ExpectedExists $true -ExpectedSha256 ([string]$registrySnapshot.sha256) -Scope 'registry critical recheck'
    foreach ($fact in @($environmentFacts)) {
        $current = Get-CodexHookEnvironmentValueFact -Name ([string]$fact.name) -Scope ([string]$fact.scope) -ReadValue $EnvironmentReadValue -Desired 'D:\Codex\.serena'
        if ($current.valueSha256 -cne $fact.valueSha256) { throw 'environment critical recheck 检测到漂移。' }
    }

    $evidenceDirectory = Join-Path $evidenceRootPath "deployment-$($plan.generationId)"
    [void](Assert-CodexHookFixturePath -Path $evidenceDirectory -Name 'evidence directory before create')
    if (Test-Path -LiteralPath $evidenceDirectory) { throw 'deployment evidence directory 已存在；拒绝重放。' }

    foreach ($stateDirectory in @($lifecyclePaths.lifecycleRoot, $lifecyclePaths.mappingRoot, $lifecyclePaths.claimsRoot)) {
        [void](New-CodexHookFixtureDirectory -Path ([string]$stateDirectory) -Name 'fixed lifecycle state directory')
    }
    $claimPath = [string]$lifecyclePaths.claimPath
    $reservationDocument = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-hook-deployment-claim'
        schemaVersion = 1
        state = 'reserved'
        generationId = [string]$plan.generationId
        mappingIdentity = $mappingIdentity
        planSha256 = [string]$planSnapshot.sha256
        evidenceDirectory = $evidenceDirectory
        restoreManifestSha256 = $null
    }
    [byte[]]$reservationBytes = [Text.UTF8Encoding]::new($false).GetBytes(($reservationDocument | ConvertTo-Json -Depth 10))
    $claimBefore = Get-CodexHookFixtureFileSnapshot -Path $claimPath -Name 'mapping-scoped claim before reserve'
    if ($claimBefore.exists) {
        throw 'deployment generationId 已被 mapping-scoped claim；拒绝重放。'
    }
    Assert-CodexHookSnapshotExpectedState -Snapshot $claimBefore -ExpectedExists $false -ExpectedSha256 $null -Scope 'mapping-scoped claim before reserve'
    $reservationSha256 = Get-CodexHookBytesSha256 -Bytes $reservationBytes
    Set-CodexHookAtomicFileBytes `
        -Path $claimPath `
        -Bytes $reservationBytes `
        -ExpectedExists $false `
        -ExpectedSha256 $null `
        -AfterSha256 $reservationSha256 `
        -Scope 'mapping-scoped claim reserve'

    [void](New-CodexHookFixtureDirectory -Path $evidenceRootPath -Name 'EvidenceRoot')
    [void](New-CodexHookFixtureDirectory -Path $evidenceDirectory -Name 'evidence directory' -RequireMissing)
    $backupsRoot = Join-Path $evidenceDirectory 'backups'
    [void](New-CodexHookFixtureDirectory -Path $backupsRoot -Name 'backups root' -RequireMissing)

    $restoreActions = [Collections.Generic.List[object]]::new()
    foreach ($action in @($plan.actions)) {
        $backupRelativePath = $null
        $backupSha256 = $null
        if ($action.beforeExists) {
            [byte[]]$beforeBytes = if ($action.kind -ceq 'registry') {
                [byte[]]$registrySnapshot.bytes
            } else {
                [byte[]]$gateTargetBytes[[string]$action.targetPath]
            }
            $backupRelativePath = "backups/$('{0:d3}' -f [int]$action.restoreOrder)-$((Get-CodexHookTextSha256 -Text ([string]$action.actionId)).Substring(0,16)).bin"
            $backupPath = Join-Path $evidenceDirectory $backupRelativePath
            $backupSha256 = Get-CodexHookBytesSha256 -Bytes $beforeBytes
            Set-CodexHookAtomicFileBytes -Path $backupPath -Bytes $beforeBytes -ExpectedExists $false -ExpectedSha256 $null -AfterSha256 $backupSha256 -Scope 'evidence backup'
        }
        $restoreActions.Add([pscustomobject][ordered]@{
            actionId = [string]$action.actionId
            kind = [string]$action.kind
            path = [string]$action.targetPath
            beforeExists = [bool]$action.beforeExists
            beforeSha256 = if ($action.beforeExists) { [string]$action.beforeSha256 } else { $null }
            backupRelativePath = $backupRelativePath
            backupSha256 = $backupSha256
            deployedExists = $true
            deployedSha256 = [string]$action.afterSha256
            restoreOrder = [int]$action.restoreOrder
            environmentName = $null
            environmentScope = $null
            environmentAfter = $null
            environmentBeforeBackupRelativePath = $null
            environmentBeforeBackupSha256 = $null
        })
    }
    foreach ($action in @($plan.environmentActions)) {
        $fact = @($environmentFacts | Where-Object { $_.name -ceq $action.name -and $_.scope -ceq $action.scope })[0]
        $backupRelativePath = "backups/$('{0:d3}' -f [int]$action.restoreOrder)-environment.json"
        $backupPath = Join-Path $evidenceDirectory $backupRelativePath
        $backupDocument = [pscustomobject][ordered]@{ present = [bool]$fact.present; value = if ($fact.present) { [string]$fact.value } else { $null } }
        [byte[]]$backupBytes = [Text.UTF8Encoding]::new($false).GetBytes(($backupDocument | ConvertTo-Json -Depth 10))
        $backupSha = Get-CodexHookBytesSha256 -Bytes $backupBytes
        Set-CodexHookAtomicFileBytes -Path $backupPath -Bytes $backupBytes -ExpectedExists $false -ExpectedSha256 $null -AfterSha256 $backupSha -Scope 'environment evidence backup'
        $restoreActions.Add([pscustomobject][ordered]@{
            actionId = [string]$action.actionId
            kind = 'environment'
            path = $null
            beforeExists = $null
            beforeSha256 = $null
            backupRelativePath = $null
            backupSha256 = $null
            deployedExists = $true
            deployedSha256 = [string]$action.afterValueSha256
            restoreOrder = [int]$action.restoreOrder
            environmentName = [string]$action.name
            environmentScope = [string]$action.scope
            environmentAfter = [string]$action.after
            environmentBeforeBackupRelativePath = $backupRelativePath
            environmentBeforeBackupSha256 = $backupSha
        })
    }

    $restoreManifest = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-hook-restore-manifest'
        schemaVersion = 1
        generationId = [string]$plan.generationId
        planSha256 = [string]$planSnapshot.sha256
        mappingIdentity = $mappingIdentity
        actions = [object[]]@($restoreActions | Sort-Object restoreOrder)
    }
    $restoreManifestPath = Join-Path $evidenceDirectory 'restore-manifest.json'
    Set-CodexHookEvidenceJson -Path $restoreManifestPath -Document $restoreManifest
    $restoreManifestSnapshot = Read-CodexHookSafeUtf8FileSnapshot -Path $restoreManifestPath -Name 'written restore manifest' -AllowedExactPaths @($restoreManifestPath)
    $claimDocument = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-hook-deployment-claim'
        schemaVersion = 1
        state = 'prepared'
        generationId = [string]$plan.generationId
        mappingIdentity = $mappingIdentity
        planSha256 = [string]$planSnapshot.sha256
        evidenceDirectory = $evidenceDirectory
        restoreManifestSha256 = [string]$restoreManifestSnapshot.sha256
    }
    Set-CodexHookEvidenceJson -Path $claimPath -Document $claimDocument

    $completedActionIds = [Collections.Generic.List[string]]::new()
    $statusPath = Join-Path $evidenceDirectory 'status.json'
    Set-CodexHookEvidenceJson -Path $statusPath -Document ([pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-hook-deployment-status'
        schemaVersion = 1
        generationId = [string]$plan.generationId
        status = 'applying'
        completedActionIds = @()
    })

    [byte[]]$desiredRegistryBytes = ConvertTo-CodexHookRegistryBytes -Registry $desiredRegistry
    $orderedActions = @(@($plan.actions) + @($plan.environmentActions) | Sort-Object restoreOrder)
    try {
        foreach ($action in $orderedActions) {
            if ($FaultInjection -ceq 'before-wrapper' -and $action.phase -ceq 'wrapper') {
                throw 'fault-injection:before-wrapper'
            }
            if ($action.kind -ceq 'file') {
                [byte[]]$publishBytes = $gateSourceBytes[[string]$action.sourceRef]
                Set-CodexHookAtomicFileBytes `
                    -Path ([string]$action.targetPath) `
                    -Bytes $publishBytes `
                    -ExpectedExists ([bool]$action.beforeExists) `
                    -ExpectedSha256 ([string]$action.beforeSha256) `
                    -AfterSha256 ([string]$action.afterSha256) `
                    -Scope 'managed file publish'
            } elseif ($action.kind -ceq 'environment') {
                $current = Get-CodexHookEnvironmentValueFact -Name ([string]$action.name) -Scope ([string]$action.scope) -ReadValue $EnvironmentReadValue -Desired ([string]$action.after)
                if ($current.valueSha256 -cne $action.beforeValueSha256) { throw 'environment 临写前漂移。' }
                Invoke-CodexHookEnvironmentAction -Action $action -ReadValue $EnvironmentReadValue -WriteValue $EnvironmentWriteValue
                $afterEnvironment = Get-CodexHookEnvironmentValueFact -Name ([string]$action.name) -Scope ([string]$action.scope) -ReadValue $EnvironmentReadValue -Desired ([string]$action.after)
                if ($afterEnvironment.valueSha256 -cne $action.afterValueSha256) { throw 'environment postcheck 失败。' }
            } elseif ($action.kind -ceq 'registry') {
                Set-CodexHookAtomicFileBytes `
                    -Path ([string]$action.targetPath) `
                    -Bytes $desiredRegistryBytes `
                    -ExpectedExists ([bool]$action.beforeExists) `
                    -ExpectedSha256 ([string]$action.beforeSha256) `
                    -AfterSha256 ([string]$action.afterSha256) `
                    -Scope 'registry publish'
                if ($FaultInjection -ceq 'registry-postcheck') { throw 'fault-injection:registry-postcheck' }
            } else {
                throw '未知 deployment action kind。'
            }
            $completedActionIds.Add([string]$action.actionId)
        }

        foreach ($postCheck in @($plan.postChecks)) {
            $action = @($plan.actions | Where-Object actionId -ceq $postCheck.actionId)
            if ($action.Count -ne 1 -or $postCheck.kind -cne 'sha256') { throw 'postcheck allowlist 非法。' }
            $current = Get-CodexHookFixtureFileSnapshot -Path ([string]$action[0].targetPath) -Name 'deployment postcheck'
            Assert-CodexHookSnapshotExpectedState -Snapshot $current -ExpectedExists $true -ExpectedSha256 ([string]$postCheck.expectedSha256) -Scope 'deployment postcheck'
        }

        Set-CodexHookEvidenceJson -Path $statusPath -Document ([pscustomobject][ordered]@{
            artifactType = 'env-governance.codex-hook-deployment-status'
            schemaVersion = 1
            generationId = [string]$plan.generationId
            status = 'applied'
            completedActionIds = [string[]]$completedActionIds.ToArray()
        })
        return [pscustomobject][ordered]@{
            applied = $true
            evidenceDirectory = $evidenceDirectory
            generationId = [string]$plan.generationId
        }
    } catch {
        $wasFaultInjection = $_.Exception.Message -like 'fault-injection:*'
        Set-CodexHookEvidenceJson -Path $statusPath -Document ([pscustomobject][ordered]@{
            artifactType = 'env-governance.codex-hook-deployment-status'
            schemaVersion = 1
            generationId = [string]$plan.generationId
            status = 'rollback-pending'
            completedActionIds = [string[]]$completedActionIds.ToArray()
        })
        try {
            [void](Restore-CodexHookDeploymentCore `
                -EvidenceDirectory $evidenceDirectory `
                -EnvironmentReadValue $EnvironmentReadValue `
                -EnvironmentWriteValue $EnvironmentWriteValue `
                -FinalStatus 'rolled-back')
        } catch {
            throw 'deployment apply 失败且自动 rollback 未完成。'
        }
        if ($wasFaultInjection) { throw 'fault-injection 已触发；自动 rollback 完成。' }
        throw 'deployment apply 失败；自动 rollback 完成。'
    }
} finally {
    if ($mutexHeld) { [void]$deploymentMutex.ReleaseMutex() }
    $deploymentMutex.Dispose()
}
