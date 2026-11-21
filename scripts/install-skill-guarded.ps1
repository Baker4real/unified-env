Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$pythonPath = 'D:\Codex\tools\python315-official\python.exe'
$wrapperPath = Join-Path $PSScriptRoot 'install_skill_guarded.py'

if (-not (Test-Path -LiteralPath $pythonPath -PathType Leaf)) {
    [Console]::Error.WriteLine("ERROR: missing managed Python runtime: $pythonPath")
    exit 2
}
if (-not (Test-Path -LiteralPath $wrapperPath -PathType Leaf)) {
    [Console]::Error.WriteLine("ERROR: missing guarded skill wrapper: $wrapperPath")
    exit 2
}

& $pythonPath -X utf8 -I $wrapperPath @args
exit $(if (Test-Path Variable:LASTEXITCODE) { $LASTEXITCODE } else { 0 })
