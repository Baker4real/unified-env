#Requires -Version 7.5
[CmdletBinding()]
param([string]$EvidenceRoot = 'D:/agents/run-evidence/antigravity-launcher-tests')

$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:SystemRoot 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
$runRoot = Join-Path ([IO.Path]::GetFullPath($EvidenceRoot)) ([guid]::NewGuid().ToString('N'))
if ([IO.Path]::GetPathRoot($runRoot) -ine 'D:\') { throw 'Fixture output requires D:.' }
[void][IO.Directory]::CreateDirectory($runRoot)
$testExe = Join-Path $runRoot 'TestLauncher.exe'
& $compiler /nologo /target:exe /main:TestLauncher /r:System.Windows.Forms.dll "/out:$testExe" (Join-Path $PSScriptRoot 'LaunchAntigravity.cs') (Join-Path $PSScriptRoot 'Test-LaunchAntigravity.cs')
if ($LASTEXITCODE -ne 0) { throw "Launcher fixture compilation failed ($LASTEXITCODE)." }
& $testExe
if ($LASTEXITCODE -ne 0) { throw "Launcher fixture failed ($LASTEXITCODE)." }
