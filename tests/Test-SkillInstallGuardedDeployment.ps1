Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Set-LineEnding([string]$Path, [string]$NewLine) {
    [IO.File]::WriteAllText($Path, ([IO.File]::ReadAllText($Path) -replace "`r?`n", $NewLine), [Text.UTF8Encoding]::new($false))
}

function Remove-FixtureRunRoot {
    param([Parameter(Mandatory)][string]$Path)

    if (-not [IO.Directory]::Exists($Path)) { return }
    $parent = Split-Path -Parent $Path
    $snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -Name 'skill install deployment test cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot $parent `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'skill install deployment test cleanup'
}

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1')
$deployPath = Join-Path $projectRoot 'scripts\Deploy-SkillInstallGuarded.ps1'
$implementationRoot = Join-Path $projectRoot 'modules\skill-supply-chain\implementation'
$wrapperPath = Join-Path $implementationRoot 'install_skill_guarded.py'
$commandWrapperPath = Join-Path $projectRoot 'scripts\install-skill-guarded.cmd'
$sourceRecordPath = Join-Path $implementationRoot 'skill_source_record.py'
$systemRepairPath = Join-Path $implementationRoot 'system_skill_provenance_repair.py'
$systemPackageProviderPath = Join-Path $implementationRoot 'system_package_identity.py'
$sourceRoot = $implementationRoot
$wrapperSource = Get-Content -LiteralPath $wrapperPath -Raw
$installerModules = @(Get-ChildItem -LiteralPath $implementationRoot -Filter 'install_skill_guarded_*.py' -File | ForEach-Object Name)
$installerSource = (@($wrapperPath) + @($installerModules | ForEach-Object { Join-Path $implementationRoot $_ }) |
    ForEach-Object { Get-Content -LiteralPath $_ -Raw }) -join "`n"
$commandWrapperSource = Get-Content -LiteralPath $commandWrapperPath -Raw

Assert-True ($installerModules.Count -gt 0) 'installer modules beside the entry are missing'
Assert-True `
    ($wrapperSource.Contains('Path(__file__).absolute().with_name("generate_skill_catalog.py")', [StringComparison]::Ordinal)) `
    'installer default generator must resolve beside the deployed wrapper'
Assert-True `
    (-not $installerSource.Contains('D:\agents\projects\统一环境\scripts\generate_skill_catalog.py', [StringComparison]::OrdinalIgnoreCase)) `
    'installer must not depend on the source repository generator path'
Assert-True (Test-Path -LiteralPath $sourceRecordPath -PathType Leaf) 'deployment source is missing the shared SOURCE.md parser'
Assert-True (Test-Path -LiteralPath $systemRepairPath -PathType Leaf) 'deployment source is missing the system provenance repair module'
Assert-True (Test-Path -LiteralPath $systemPackageProviderPath -PathType Leaf) 'deployment source is missing the Store package identity provider'
Assert-True `
    ($commandWrapperSource.Contains('"%CODEX_PYTHON%" -X utf8 -I "%WRAPPER%" %*', [StringComparison]::Ordinal)) `
    'production command wrapper must enable UTF-8 mode before isolated execution'

# Each run keeps its fixtures under its own root and removes that root, pass or fail.
$runRoot = Join-Path 'D:\Codex\tmp\skill-install-guarded-deployment-fixture' ('run-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $runRoot | Out-Null
$cleanupError = $null
try {
    $shadowRoot = Join-Path $runRoot 'yaml-shadow'
    $shadowModule = Join-Path $shadowRoot 'yaml.py'
    $hadPythonPath = Test-Path Env:PYTHONPATH
    $previousPythonPath = $env:PYTHONPATH
    $hadDontWriteBytecode = Test-Path Env:PYTHONDONTWRITEBYTECODE
    $previousDontWriteBytecode = $env:PYTHONDONTWRITEBYTECODE
    try {
        New-Item -ItemType Directory -Path $shadowRoot | Out-Null
        [IO.File]::WriteAllText(
            $shadowModule,
            "raise RuntimeError('untrusted yaml shadow imported')`n",
            [Text.UTF8Encoding]::new($false)
        )
        $env:PYTHONPATH = $shadowRoot
        $env:PYTHONDONTWRITEBYTECODE = '1'
        $result = & $deployPath `
            -SourceRoot $sourceRoot `
            -AllowUncommittedSource `
            -CodexRoot (Join-Path $runRoot 'whatif-codex') `
            -EvidenceRoot (Join-Path $runRoot 'whatif-evidence') `
            -WhatIf
        $wrapperHelpOutput = @(& $commandWrapperPath --help 2>&1)
        $wrapperHelpExitCode = $LASTEXITCODE
    }
    finally {
        if ($hadPythonPath) { $env:PYTHONPATH = $previousPythonPath }
        else { Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue }
        if ($hadDontWriteBytecode) { $env:PYTHONDONTWRITEBYTECODE = $previousDontWriteBytecode }
        else { Remove-Item Env:PYTHONDONTWRITEBYTECODE -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $shadowModule -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $shadowRoot -Force -ErrorAction SilentlyContinue
    }

    $wrapperHelpText = $wrapperHelpOutput | Out-String
    Assert-True `
        ($wrapperHelpExitCode -eq 0) `
        "production command wrapper must ignore PYTHONPATH yaml shadowing; exit=$wrapperHelpExitCode output=$wrapperHelpText"
    Assert-True `
        (-not $wrapperHelpText.Contains('untrusted yaml shadow imported', [StringComparison]::Ordinal)) `
        'production command wrapper imported the untrusted yaml shadow module'

    $relativeFiles = @($result.files | ForEach-Object { [string]$_.relative })
    Assert-True ($result.status -ceq 'what-if') 'deployment fixture must remain a WhatIf'
    Assert-True ($result.yamlDependency -ceq 'passed') 'deployment must verify the managed Python PyYAML dependency'
    Assert-True ($relativeFiles.Count -eq 6 + $installerModules.Count) 'deployment bundle must contain the six base runtime files plus every installer module'
    foreach ($installerModule in $installerModules) {
        Assert-True ($relativeFiles -contains $installerModule) "deployment bundle is missing installer module $installerModule"
    }
    Assert-True ($relativeFiles -contains 'skill_source_record.py') 'deployment bundle is missing the shared SOURCE.md parser'
    Assert-True ($relativeFiles -contains 'install_skill_guarded.py') 'deployment bundle is missing the Python wrapper'
    Assert-True ($relativeFiles -contains 'install-skill-guarded.cmd') 'deployment bundle is missing the command wrapper'
    Assert-True ($relativeFiles -contains 'generate_skill_catalog.py') 'deployment bundle is missing the catalog generator'
    Assert-True ($relativeFiles -contains 'system_skill_provenance_repair.py') 'deployment bundle is missing the system provenance repair module'
    Assert-True ($relativeFiles -contains 'system_package_identity.py') 'deployment bundle is missing the Store package identity provider'

    $realCodexRoot = Join-Path $runRoot 'real-codex'
    $realEvidenceRoot = Join-Path $runRoot 'real-evidence'
    $realResult = & $deployPath `
        -SourceRoot $sourceRoot `
        -AllowUncommittedSource `
        -CodexRoot $realCodexRoot `
        -EvidenceRoot $realEvidenceRoot
    Assert-True ($realResult.status -ceq 'succeeded') 'real deployment must succeed'
    foreach ($record in @($realResult.files)) {
        Assert-True ((Get-FileHash -LiteralPath ([string]$record.target) -Algorithm SHA256).Hash.ToUpperInvariant() -ceq [string]$record.sourceSha256) "real deployment hash mismatch: $($record.relative)"
        Assert-True ($null -ne $record.writtenIdentity) "real deployment must record written identity: $($record.relative)"
    }
    $realManifest = Get-Content -LiteralPath (Join-Path ([string]$realResult.evidence) 'manifest.json') -Raw | ConvertFrom-Json
    Assert-True ($realManifest.status -ceq 'succeeded') 'real deployment manifest must be succeeded'
    Assert-True ($realManifest.sourceCommitCheck -ceq 'skipped') 'real deployment manifest must record the skipped source commit check'
    # The installer modules load from the deployed directory, but a yaml.py there must never shadow PyYAML.
    $deployedYamlShadow = Join-Path $realCodexRoot 'scripts\yaml.py'
    [IO.File]::WriteAllText(
        $deployedYamlShadow,
        "raise RuntimeError('untrusted yaml shadow imported')`n",
        [Text.UTF8Encoding]::new($false)
    )
    try {
        $deployedHelpOutput = @(& (Join-Path $realCodexRoot 'scripts\install-skill-guarded.cmd') --help 2>&1)
        $deployedHelpExitCode = $LASTEXITCODE
    }
    finally {
        Remove-Item -LiteralPath $deployedYamlShadow -Force -ErrorAction SilentlyContinue
    }
    Assert-True `
        ($deployedHelpExitCode -eq 0) `
        "deployed command wrapper must load every installer module from its own directory and ignore a yaml.py there; exit=$deployedHelpExitCode output=$($deployedHelpOutput | Out-String)"
    Assert-True `
        (-not (Test-Path -LiteralPath (Join-Path $realCodexRoot 'scripts\__pycache__'))) `
        'deployed installer must not write bytecode beside itself'

    $rollbackCodexRoot = Join-Path $runRoot 'rollback-codex'
    $rollbackEvidenceRoot = Join-Path $runRoot 'rollback-evidence'
    $rollbackScriptsRoot = Join-Path $rollbackCodexRoot 'scripts'
    New-Item -ItemType Directory -Path $rollbackScriptsRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $rollbackScriptsRoot 'generate_skill_catalog.py') -Force | Out-Null
    $rollbackFailure = $null
    try {
        $null = & $deployPath `
            -SourceRoot $sourceRoot `
            -AllowUncommittedSource `
            -CodexRoot $rollbackCodexRoot `
            -EvidenceRoot $rollbackEvidenceRoot `
            2>&1
    }
    catch { $rollbackFailure = $_ }
    Assert-True ($null -ne $rollbackFailure) 'deployment must fail against a pre-existing target directory'
    $rollbackManifestPath = Get-ChildItem -LiteralPath $rollbackEvidenceRoot -Filter 'manifest.json' -Recurse | Select-Object -First 1 -ExpandProperty FullName
    Assert-True ($null -ne $rollbackManifestPath) 'rollback deployment must leave a manifest'
    $rollbackManifest = Get-Content -LiteralPath $rollbackManifestPath -Raw | ConvertFrom-Json
    Assert-True ($rollbackManifest.status -ceq 'rolled-back') 'failed deployment must roll back'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $rollbackScriptsRoot 'skill_source_record.py') -PathType Leaf)) 'rollback must remove the first deployed file'
    Assert-True (Test-Path -LiteralPath (Join-Path $rollbackScriptsRoot 'generate_skill_catalog.py') -PathType Container) 'rollback must preserve the pre-existing target directory'

    $failureCodexRoot = Join-Path $runRoot 'failure-codex'
    $failureEvidenceRoot = Join-Path $runRoot 'failure-evidence'
    $failureRuntimeRoot = Join-Path $runRoot 'failure-runtime'
    $nonPythonPath = Join-Path $failureRuntimeRoot 'not-python.exe'
    $dependencyFailure = $null
    try {
        New-Item -ItemType Directory -Path $failureRuntimeRoot | Out-Null
        Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\where.exe') -Destination $nonPythonPath
        try {
            $null = & $deployPath `
                -SourceRoot $sourceRoot `
                -AllowUncommittedSource `
                -CodexRoot $failureCodexRoot `
                -EvidenceRoot $failureEvidenceRoot `
                -PythonPath $nonPythonPath `
                2>&1
        }
        catch {
            $dependencyFailure = $_
        }

        Assert-True ($null -ne $dependencyFailure) 'deployment must fail when the target runtime cannot import PyYAML'
        Assert-True `
            ($dependencyFailure.Exception.Message -like '*缺少 PyYAML*') `
            'deployment must report the missing PyYAML dependency'
        Assert-True (-not (Test-Path -LiteralPath $failureCodexRoot)) 'failed dependency probe must not create the target Codex root'
        Assert-True (-not (Test-Path -LiteralPath $failureEvidenceRoot)) 'failed dependency probe must not create deployment evidence'
    }
    finally {
        Remove-Item -LiteralPath $nonPythonPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $failureRuntimeRoot -Force -ErrorAction SilentlyContinue
    }

    # Sessions share the project work tree; a deploy must not ship bytes that no commit holds.
    $sourceRepo = Join-Path $runRoot 'source-repo'
    $sourceRepoImplementation = Join-Path $sourceRepo 'modules\skill-supply-chain\implementation'
    $sourceRepoScripts = Join-Path $sourceRepo 'scripts'
    New-Item -ItemType Directory -Path $sourceRepoImplementation, $sourceRepoScripts | Out-Null
    Copy-Item -LiteralPath $deployPath, $commandWrapperPath -Destination $sourceRepoScripts
    foreach ($relative in @($relativeFiles | Where-Object { $_ -cne 'install-skill-guarded.cmd' })) {
        Copy-Item -LiteralPath (Join-Path $implementationRoot $relative) -Destination $sourceRepoImplementation
    }
    # A git archive snapshot holds the same layout outside any work tree.
    $snapshot = Join-Path $runRoot 'snapshot'
    Copy-Item -LiteralPath $sourceRepo -Destination $snapshot -Recurse
    $snapshotResult = & (Join-Path $snapshot 'scripts\Deploy-SkillInstallGuarded.ps1') `
        -CodexRoot (Join-Path $runRoot 'snapshot-codex') `
        -EvidenceRoot (Join-Path $runRoot 'snapshot-evidence') `
        -WhatIf
    Assert-True ($snapshotResult.sourceCommitCheck -ceq 'outside-work-tree') 'a snapshot outside any work tree must deploy without the commit check'
    # Under core.autocrlf=true, the Windows default, git status leaves CRLF already committed alone (the .cmd)
    # and normalizes CRLF that a checkout wrote over an LF blob (the .py); neither is an uncommitted change.
    $crlfCommittedPath = Join-Path $sourceRepoScripts 'install-skill-guarded.cmd'
    $crlfCheckoutPath = Join-Path $sourceRepoImplementation 'skill_source_record.py'
    Set-LineEnding $crlfCommittedPath "`r`n"
    Set-LineEnding $crlfCheckoutPath "`n"
    & git -C $sourceRepo -c init.defaultBranch=main init -q
    & git -C $sourceRepo config core.autocrlf true
    & git -C $sourceRepo -c core.autocrlf=false add --all
    & git -C $sourceRepo -c user.name=fixture -c user.email=fixture@invalid commit -q -m fixture
    Assert-True ($LASTEXITCODE -eq 0) 'fixture source repository must commit the deployment sources'
    Set-LineEnding $crlfCheckoutPath "`r`n"
    $sourceRepoDeployPath = Join-Path $sourceRepoScripts 'Deploy-SkillInstallGuarded.ps1'
    $committedResult = & $sourceRepoDeployPath `
        -CodexRoot (Join-Path $runRoot 'committed-codex') `
        -EvidenceRoot (Join-Path $runRoot 'committed-evidence') `
        -WhatIf
    Assert-True ($committedResult.sourceCommitCheck -ceq 'matches-head') 'a work-tree source that matches HEAD, CRLF included, must pass the commit check'
    [IO.File]::AppendAllText((Join-Path $sourceRepoImplementation 'install_skill_guarded_system_overlay.py'), "# another session, not committed`n")
    [IO.File]::AppendAllText((Join-Path $sourceRepoScripts 'install-skill-guarded.cmd'), "rem another session, not committed`n")
    $uncommittedCodexRoot = Join-Path $runRoot 'uncommitted-codex'
    $uncommittedEvidenceRoot = Join-Path $runRoot 'uncommitted-evidence'
    foreach ($whatIf in $true, $false) {
        $uncommittedFailure = $null
        try {
            $null = & $sourceRepoDeployPath `
                -CodexRoot $uncommittedCodexRoot `
                -EvidenceRoot $uncommittedEvidenceRoot `
                -WhatIf:$whatIf `
                2>&1
        }
        catch { $uncommittedFailure = $_ }
        Assert-True ($null -ne $uncommittedFailure) "deployment must refuse sources that differ from HEAD (WhatIf=$whatIf)"
        foreach ($name in 'install_skill_guarded_system_overlay.py', 'install-skill-guarded.cmd') {
            Assert-True ($uncommittedFailure.Exception.Message.Contains($name, [StringComparison]::Ordinal)) "refusal must name $name (WhatIf=$whatIf)"
        }
        Assert-True (-not (Test-Path -LiteralPath $uncommittedCodexRoot)) 'refused deployment must not create the target Codex root'
        Assert-True (-not (Test-Path -LiteralPath $uncommittedEvidenceRoot)) 'refused deployment must not create deployment evidence'
    }
    $allowedResult = & $sourceRepoDeployPath `
        -CodexRoot $uncommittedCodexRoot `
        -EvidenceRoot $uncommittedEvidenceRoot `
        -AllowUncommittedSource `
        -WhatIf
    Assert-True ($allowedResult.status -ceq 'what-if') '-AllowUncommittedSource must let an uncommitted source through'
    Assert-True ($allowedResult.sourceCommitCheck -ceq 'skipped') '-AllowUncommittedSource must record the skipped commit check'
}
finally {
    # A failed run keeps its own error; a cleanup error surfaces only after a passing run.
    try { Remove-FixtureRunRoot -Path $runRoot }
    catch { $cleanupError = $_ }
}
if ($null -ne $cleanupError) { throw $cleanupError }
Assert-True (-not (Test-Path -LiteralPath $runRoot)) "deployment test must remove its fixture run root: $runRoot"

Write-Output "PASS Test-SkillInstallGuardedDeployment files=$($relativeFiles.Count) whatIf=1 real=1 deployedHelp=passed rollback=1 yamlDependency=passed runtimeIsolation=passed missingYamlFailure=passed repositoryPathDependency=0 uncommittedSource=refused sourceCommitStates=3 fixtureRunRoot=removed"
