Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$errors = $null
$tokens = $null
$path = 'D:\Codex\projects\统一环境\tests\Test-CodexSafeTreeDeletePhase1Integration.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($null -eq $ast) { throw 'parse returned null AST' }
if ($null -ne $errors -and $errors.Count -gt 0) {
    throw ($errors | ForEach-Object { $_.ToString() } | Join-String -Separator "`n")
}
Write-Output 'PARSE_OK'
