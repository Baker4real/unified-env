Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$projectRoot = Split-Path -Parent $PSScriptRoot
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

$shadowRoot = Join-Path 'D:\Codex\tmp\skill-install-guarded-deployment-fixture' ('yaml-shadow-' + [guid]::NewGuid().ToString('N'))
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
        -CodexRoot 'D:\Codex\tmp\skill-install-guarded-deployment-fixture\codex-home' `
        -EvidenceRoot 'D:\Codex\tmp\skill-install-guarded-deployment-fixture\evidence' `
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

$realId = [guid]::NewGuid().ToString('N')
$realCodexRoot = Join-Path 'D:\Codex\tmp\skill-install-guarded-deployment-fixture' ("real-$realId-codex")
$realEvidenceRoot = Join-Path 'D:\Codex\tmp\skill-install-guarded-deployment-fixture' ("real-$realId-evidence")
$realResult = & $deployPath `
    -SourceRoot $sourceRoot `
    -CodexRoot $realCodexRoot `
    -EvidenceRoot $realEvidenceRoot
Assert-True ($realResult.status -ceq 'succeeded') 'real deployment must succeed'
foreach ($record in @($realResult.files)) {
    Assert-True ((Get-FileHash -LiteralPath ([string]$record.target) -Algorithm SHA256).Hash.ToUpperInvariant() -ceq [string]$record.sourceSha256) "real deployment hash mismatch: $($record.relative)"
    Assert-True ($null -ne $record.writtenIdentity) "real deployment must record written identity: $($record.relative)"
}
$realManifest = Get-Content -LiteralPath (Join-Path ([string]$realResult.evidence) 'manifest.json') -Raw | ConvertFrom-Json
Assert-True ($realManifest.status -ceq 'succeeded') 'real deployment manifest must be succeeded'
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

$rollbackId = [guid]::NewGuid().ToString('N')
$rollbackCodexRoot = Join-Path 'D:\Codex\tmp\skill-install-guarded-deployment-fixture' ("rollback-$rollbackId-codex")
$rollbackEvidenceRoot = Join-Path 'D:\Codex\tmp\skill-install-guarded-deployment-fixture' ("rollback-$rollbackId-evidence")
$rollbackScriptsRoot = Join-Path $rollbackCodexRoot 'scripts'
New-Item -ItemType Directory -Path $rollbackScriptsRoot -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $rollbackScriptsRoot 'generate_skill_catalog.py') -Force | Out-Null
$rollbackFailure = $null
try {
    $null = & $deployPath `
        -SourceRoot $sourceRoot `
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

$failureId = [guid]::NewGuid().ToString('N')
$failureCodexRoot = Join-Path 'D:\Codex\tmp\skill-install-guarded-deployment-fixture' ("failure-$failureId-codex")
$failureEvidenceRoot = Join-Path 'D:\Codex\tmp\skill-install-guarded-deployment-fixture' ("failure-$failureId-evidence")
$failureRuntimeRoot = Join-Path 'D:\Codex\tmp\skill-install-guarded-deployment-fixture' ("failure-$failureId-runtime")
$nonPythonPath = Join-Path $failureRuntimeRoot 'not-python.exe'
$dependencyFailure = $null
try {
    New-Item -ItemType Directory -Path $failureRuntimeRoot | Out-Null
    Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\where.exe') -Destination $nonPythonPath
    try {
        $null = & $deployPath `
            -SourceRoot $sourceRoot `
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

Write-Output "PASS Test-SkillInstallGuardedDeployment files=$($relativeFiles.Count) whatIf=1 real=1 deployedHelp=passed rollback=1 yamlDependency=passed runtimeIsolation=passed missingYamlFailure=passed repositoryPathDependency=0"
