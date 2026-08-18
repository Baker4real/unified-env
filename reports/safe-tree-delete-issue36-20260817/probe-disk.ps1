Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$d = [IO.DriveInfo]::new('D:\')
[pscustomobject][ordered]@{
    edition = [string]$PSVersionTable.PSEdition
    version = $PSVersionTable.PSVersion.ToString()
    driveFormat = [string]$d.DriveFormat
    driveType = [string]$d.DriveType
    availableFreeBytes = [long]$d.AvailableFreeSpace
    totalSizeBytes = [long]$d.TotalSize
} | ConvertTo-Json -Compress
