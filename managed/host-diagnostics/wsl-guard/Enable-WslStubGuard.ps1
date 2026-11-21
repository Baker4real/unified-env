#Requires -Version 7.5
[CmdletBinding()]
param(
    [string]$ResultPath
)
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) {
    throw 'Administrator privileges are required to configure HKLM Image File Execution Options.'
}

$wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
$vbs = 'D:\Codex\tools\wsl-guard\wsl-disabled.vbs'
if (-not (Test-Path -LiteralPath $wscript -PathType Leaf)) { throw "Missing wscript.exe: $wscript" }
if (-not (Test-Path -LiteralPath $vbs -PathType Leaf)) { throw "Missing guard script: $vbs" }

$debuggerValue = "`"$wscript`" //B //NoLogo `"$vbs`""
$keys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\wsl.exe',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\wsl.exe'
)

$records = [Collections.Generic.List[object]]::new()
foreach ($key in $keys) {
    $before = $null
    if (Test-Path -LiteralPath $key) {
        $prop = Get-ItemProperty -LiteralPath $key -Name 'Debugger' -ErrorAction SilentlyContinue
        if ($null -ne $prop) { $before = $prop.Debugger }
    }
    else {
        [void](New-Item -Path $key -Force)
    }
    Set-ItemProperty -LiteralPath $key -Name 'Debugger' -Value $debuggerValue -Type String
    $after = (Get-ItemProperty -LiteralPath $key -Name 'Debugger' -ErrorAction Stop).Debugger
    if ($after -cne $debuggerValue) {
        throw "Readback mismatch for $key"
    }
    $records.Add([pscustomobject]@{
        key = $key
        before = $before
        after = $after
    })
}

$report = [pscustomobject]@{
    status = 'enabled'
    appliedAt = (Get-Date).ToString('o')
    debugger = $debuggerValue
    keys = @($records)
}
$json = ConvertTo-Json -InputObject $report -Depth 4
if ($ResultPath) {
    $dir = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ResultPath))
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        [void][IO.Directory]::CreateDirectory($dir)
    }
    [IO.File]::WriteAllText($ResultPath, $json, $utf8)
}
$json
