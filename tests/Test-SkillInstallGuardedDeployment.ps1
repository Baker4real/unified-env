Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$deployPath = Join-Path $projectRoot 'scripts\Deploy-SkillInstallGuarded.ps1'
$wrapperPath = Join-Path $projectRoot 'scripts\install_skill_guarded.py'
$sourceRoot = Join-Path $projectRoot 'scripts'
$wrapperSource = Get-Content -LiteralPath $wrapperPath -Raw

Assert-True `
    ($wrapperSource.Contains('Path(__file__).absolute().with_name("generate_skill_catalog.py")', [StringComparison]::Ordinal)) `
    'installer default generator must resolve beside the deployed wrapper'
Assert-True `
    (-not $wrapperSource.Contains('D:\Codex\projects\统一环境\scripts\generate_skill_catalog.py', [StringComparison]::OrdinalIgnoreCase)) `
    'installer must not depend on the source repository generator path'

$result = & $deployPath `
    -SourceRoot $sourceRoot `
    -CodexRoot 'D:\Codex\tmp\skill-install-guarded-deployment-fixture\codex-home' `
    -EvidenceRoot 'D:\Codex\tmp\skill-install-guarded-deployment-fixture\evidence' `
    -WhatIf

$relativeFiles = @($result.files | ForEach-Object { [string]$_.relative })
Assert-True ($result.status -ceq 'what-if') 'deployment fixture must remain a WhatIf'
Assert-True ($relativeFiles.Count -eq 3) 'deployment bundle must contain exactly three runtime files'
Assert-True ($relativeFiles -contains 'install_skill_guarded.py') 'deployment bundle is missing the Python wrapper'
Assert-True ($relativeFiles -contains 'install-skill-guarded.cmd') 'deployment bundle is missing the command wrapper'
Assert-True ($relativeFiles -contains 'generate_skill_catalog.py') 'deployment bundle is missing the catalog generator'

Write-Output 'PASS Test-SkillInstallGuardedDeployment files=3 whatIf=1 repositoryPathDependency=0'
