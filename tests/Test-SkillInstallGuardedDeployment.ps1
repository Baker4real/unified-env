Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$deployPath = Join-Path $projectRoot 'scripts\Deploy-SkillInstallGuarded.ps1'
$wrapperPath = Join-Path $projectRoot 'scripts\install_skill_guarded.py'
$commandWrapperPath = Join-Path $projectRoot 'scripts\install-skill-guarded.cmd'
$sourceRecordPath = Join-Path $projectRoot 'scripts\skill_source_record.py'
$sourceRoot = Join-Path $projectRoot 'scripts'
$wrapperSource = Get-Content -LiteralPath $wrapperPath -Raw
$commandWrapperSource = Get-Content -LiteralPath $commandWrapperPath -Raw

Assert-True `
    ($wrapperSource.Contains('Path(__file__).absolute().with_name("generate_skill_catalog.py")', [StringComparison]::Ordinal)) `
    'installer default generator must resolve beside the deployed wrapper'
Assert-True `
    (-not $wrapperSource.Contains('D:\Codex\projects\统一环境\scripts\generate_skill_catalog.py', [StringComparison]::OrdinalIgnoreCase)) `
    'installer must not depend on the source repository generator path'
Assert-True (Test-Path -LiteralPath $sourceRecordPath -PathType Leaf) 'deployment source is missing the shared SOURCE.md parser'
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
Assert-True ($relativeFiles.Count -eq 4) 'deployment bundle must contain exactly four runtime files'
Assert-True ($relativeFiles -contains 'skill_source_record.py') 'deployment bundle is missing the shared SOURCE.md parser'
Assert-True ($relativeFiles -contains 'install_skill_guarded.py') 'deployment bundle is missing the Python wrapper'
Assert-True ($relativeFiles -contains 'install-skill-guarded.cmd') 'deployment bundle is missing the command wrapper'
Assert-True ($relativeFiles -contains 'generate_skill_catalog.py') 'deployment bundle is missing the catalog generator'

$failureId = [guid]::NewGuid().ToString('N')
$failureCodexRoot = Join-Path 'D:\Codex\tmp\skill-install-guarded-deployment-fixture' ("failure-$failureId-codex")
$failureEvidenceRoot = Join-Path 'D:\Codex\tmp\skill-install-guarded-deployment-fixture' ("failure-$failureId-evidence")
$nonPythonPath = Join-Path $PSHOME 'pwsh.exe'
$dependencyFailure = $null
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

Write-Output 'PASS Test-SkillInstallGuardedDeployment files=4 whatIf=1 yamlDependency=passed runtimeIsolation=passed missingYamlFailure=passed repositoryPathDependency=0'
