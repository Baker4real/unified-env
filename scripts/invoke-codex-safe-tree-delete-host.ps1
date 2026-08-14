Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

& 'D:\Codex\projects\统一环境\scripts\Invoke-CodexSafeTreeDelete.ps1' @args
exit $(if (Test-Path Variable:LASTEXITCODE) { $LASTEXITCODE } else { 0 })
