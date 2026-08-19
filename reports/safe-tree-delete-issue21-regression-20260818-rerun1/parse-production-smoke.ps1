Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$path = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tests\Test-CodexSafeTreeDeleteProductionSmoke.ps1'
$errors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
if ($errors -and $errors.Count -gt 0) {
    $errors | ForEach-Object { $_.ToString() }
    exit 1
}
Write-Output 'PARSE_OK'
exit 0
