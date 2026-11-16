<#
.SYNOPSIS
Read-only channel-specific validation of official installed Codex Appx signatures.
.DESCRIPTION
StoreMain requires exactly OpenAI.Codex, Store, and the fixed Store publisher identity.
PrimaryRuntime requires OpenAI.CodexPrimaryRuntime.v*, Developer, and OpenAI OpCo's publisher DN.
Both channels require valid CMS, a bound RFC3161 timestamp, and trusted chains at that timestamp.
No installation, package mutation, certificate-store mutation, or certificate downloads occur.
This validates signature evidence; it does not rehash installed payloads or check revocation.
Evidence is a separate, caller-supplied public seam for offline cryptographic fixture regression.
.EXAMPLE
./scripts/Test-OfficialPackageSignature.ps1 -Channel StoreMain -AsJson
.EXAMPLE
./scripts/Test-OfficialPackageSignature.ps1 -Channel PrimaryRuntime -AsJson
#>
[CmdletBinding(DefaultParameterSetName = 'Installed')]
param(
    [Parameter(Mandatory)][ValidateSet('StoreMain', 'PrimaryRuntime')][string]$Channel,
    [Parameter(ParameterSetName = 'Installed')][string]$PackageFullName,
    [Parameter(Mandatory, ParameterSetName = 'Evidence')][psobject]$Evidence,
    [Parameter(ParameterSetName = 'Evidence')]
    [System.Security.Cryptography.X509Certificates.X509Certificate2[]]$TrustRoot = @(),
    [Parameter(ParameterSetName = 'Evidence')][datetimeoffset]$VerificationTime = [datetimeoffset]::UtcNow,
    [switch]$AsJson
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'lib/OfficialPackageSignature.psm1') -Force

if ($PSCmdlet.ParameterSetName -eq 'Evidence') {
    $results = @(Test-OfficialPackageSignatureEvidence -Channel $Channel -Evidence $Evidence `
        -TrustRoot $TrustRoot -VerificationTime $VerificationTime)
} else {
    if (-not $IsWindows) { throw 'installed-appx-validation-requires-windows' }
    $name = if ($Channel -eq 'StoreMain') { 'OpenAI.Codex' } else { 'OpenAI.CodexPrimaryRuntime.*' }
    $packages = @(Get-AppxPackage -Name $name -ErrorAction Stop)
    if ($PackageFullName) {
        $packages = @($packages | Where-Object { $_.PackageFullName -ceq $PackageFullName })
    }
    if ($packages.Count -eq 0) { throw 'no-matching-installed-package' }
    if ($Channel -eq 'StoreMain' -and $packages.Count -ne 1) { throw 'store-package-not-unique' }
    $results = @(foreach ($package in $packages) {
        $signaturePath = Join-Path ([string]$package.InstallLocation) 'AppxSignature.p7x'
        $item = Get-Item -LiteralPath $signaturePath -Force -ErrorAction Stop
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'signature-must-be-ordinary-file'
        }
        for ($directory = $item.Directory; $null -ne $directory; $directory = $directory.Parent) {
            if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'signature-ancestor-must-not-be-reparse-point'
            }
        }
        $record = [pscustomobject]@{
            Name = [string]$package.Name
            Publisher = [string]$package.Publisher
            SignatureKind = [string]$package.SignatureKind
            Status = [string]$package.Status
            SignatureBytes = [IO.File]::ReadAllBytes($signaturePath)
        }
        $result = Test-OfficialPackageSignatureEvidence -Channel $Channel -Evidence $record
        $result.evidence_source = 'installed-appx-registration'
        $result | Add-Member -NotePropertyName package_full_name -NotePropertyValue ([string]$package.PackageFullName)
        $result | Add-Member -NotePropertyName signature_path -NotePropertyValue $signaturePath
        $result
    })
}
if ($AsJson) {
    ConvertTo-Json -InputObject $results -Depth 5
} else { $results }
