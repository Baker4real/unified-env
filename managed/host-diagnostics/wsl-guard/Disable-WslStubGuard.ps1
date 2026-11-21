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
    throw 'Administrator privileges are required to remove HKLM Image File Execution Options.'
}

$keys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\wsl.exe',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\wsl.exe'
)

$records = [Collections.Generic.List[object]]::new()
foreach ($key in $keys) {
    $before = $null
    $keyRemoved = $false
    if (Test-Path -LiteralPath $key) {
        $prop = Get-ItemProperty -LiteralPath $key -Name 'Debugger' -ErrorAction SilentlyContinue
        if ($null -ne $prop) {
            $before = $prop.Debugger
            Remove-ItemProperty -LiteralPath $key -Name 'Debugger' -ErrorAction Stop
        }
        $item = Get-Item -LiteralPath $key -ErrorAction Stop
        if ($item.ValueCount -eq 0 -and $item.SubKeyCount -eq 0) {
            Remove-Item -LiteralPath $key -ErrorAction Stop
            $keyRemoved = $true
        }
    }
    $afterExists = Test-Path -LiteralPath $key
    $afterDebugger = if ($afterExists) {
        $p = Get-ItemProperty -LiteralPath $key -Name 'Debugger' -ErrorAction SilentlyContinue
        if ($null -ne $p) { $p.Debugger } else { $null }
    } else { $null }
    if ($null -ne $afterDebugger) {
        throw "Debugger value still present on $key"
    }
    $records.Add([pscustomobject]@{
        key = $key
        before = $before
        keyRemoved = $keyRemoved
        afterExists = $afterExists
    })
}

$report = [pscustomobject]@{
    status = 'disabled'
    appliedAt = (Get-Date).ToString('o')
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
