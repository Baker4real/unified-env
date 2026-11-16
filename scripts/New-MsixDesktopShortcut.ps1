<#
.SYNOPSIS
Plan or apply an identity-bound MSIX shortcut with official, native-size DIB icon frames.
.DESCRIPTION
Only an installed, healthy Store-signed package is accepted. The package manifest supplies
Application Id and Square44x44Logo; its targetsize PNGs supply every ICO frame, through 256.
The default Plan performs no file writes. Apply is an explicitly authorized operation.
Both output parents must exist on D:. Existing links must already target explorer.exe with
the exact AppsFolder AUMID. Only their icon is changed; original bytes are backed up.
An existing ICO is replaceable only when that identity-checked link already references it.
Failure restores published files; success returns exact backup paths for manual recovery.
No application is launched, Explorer is not restarted, and icon caches are not deleted.
.EXAMPLE
./scripts/New-MsixDesktopShortcut.ps1 -PackageName OpenAI.Codex -PackageFamilyName OpenAI.Codex_2p2nqsd0c76g0 -ApplicationId App -ShortcutPath D:/Desktop/Codex.lnk -IconPath D:/Codex/host-assets/Codex.ico
.EXAMPLE
./scripts/New-MsixDesktopShortcut.ps1 -PackageName OpenAI.Codex -PackageFamilyName OpenAI.Codex_2p2nqsd0c76g0 -ApplicationId App -ShortcutPath D:/Desktop/Codex.lnk -IconPath D:/Codex/host-assets/Codex.ico -Mode Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackageName,
    [Parameter(Mandatory)][string]$PackageFamilyName,
    [Parameter(Mandatory)][string]$ApplicationId,
    [Parameter(Mandatory)][string]$ShortcutPath,
    [Parameter(Mandatory)][string]$IconPath,
    [ValidateSet('Plan','Apply')][string]$Mode = 'Plan'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows -or $PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.Major -lt 7) { throw 'Windows PowerShell Core 7+ is required.' }
Import-Module (Join-Path $PSScriptRoot 'lib/MsixShortcutIcon.psm1') -Force -DisableNameChecking
$context = Get-MsixInstalledPackageContext -PackageName $PackageName -PackageFamilyName $PackageFamilyName -ApplicationId $ApplicationId
Invoke-MsixDesktopShortcut -PackageContext $context -ShortcutPath $ShortcutPath -IconPath $IconPath -Mode $Mode
