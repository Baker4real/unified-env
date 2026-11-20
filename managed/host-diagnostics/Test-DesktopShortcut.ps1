#Requires -Version 7.5
[CmdletBinding()]
param([string]$EvidenceRoot = 'D:/agents/run-evidence/desktop-shortcut-tests')

$ErrorActionPreference = 'Stop'
$runRoot = Join-Path ([IO.Path]::GetFullPath($EvidenceRoot)) ([guid]::NewGuid().ToString('N'))
if ([IO.Path]::GetPathRoot($runRoot) -ine 'D:\') { throw 'Fixture output requires D:.' }
[void][IO.Directory]::CreateDirectory($runRoot)
$entry = Join-Path $PSScriptRoot 'Open-DesktopShortcut.ps1'
$link = Join-Path $runRoot 'shortcut with spaces.lnk'
$target = Join-Path $env:SystemRoot 'explorer.exe'
$other = Join-Path $env:SystemRoot 'System32/cmd.exe'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($link)
$shortcut.TargetPath = $target
$shortcut.Arguments = '/n'
$shortcut.Save()

$plan = & $entry -Mode Plan -ShortcutPath $link -ExpectedTarget $target -ExecutablePath $other -ExpectedArguments '/n'
if ($plan.status -ne 'planned' -or $plan.target -ne $target -or $plan.executable -ne [IO.Path]::GetFullPath($other)) {
    throw 'The desktop plan did not bind the observed link and expected window executable.'
}
foreach ($case in @(@{target=$other; arguments='/n'}, @{target=$target; arguments=''})) {
    $refused = $false
    try { $null = & $entry -Mode Plan -ShortcutPath $link -ExpectedTarget $case.target -ExecutablePath $other -ExpectedArguments $case.arguments }
    catch { $refused = $_.Exception.Message -eq 'shortcut-target-or-arguments-changed' }
    if (-not $refused) { throw 'The desktop plan accepted shortcut drift.' }
}
'Explorer shortcut plan verified target binding, arguments and drift refusal.'
