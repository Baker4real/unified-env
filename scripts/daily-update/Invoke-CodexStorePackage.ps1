#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Proof','Verify','Register','Rollback')][string]$Mode,
    [Parameter(Mandatory)][ValidatePattern('^\d{1,5}(\.\d{1,5}){3}$')][string]$Version,
    [ValidatePattern('^\d{1,5}(\.\d{1,5}){3}$')][string]$CurrentVersion,
    [string]$Archive,
    [ValidatePattern('^[0-9a-f]{64}$')][string]$ArchiveSha256
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$family = 'OpenAI.Codex_2p2nqsd0c76g0'
$publisher = '50BDFD77-8903-4850-9FFE-6E8522F64D5B'
$storeRoot = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'WindowsApps'
$serviceName = 'CodexSandboxService.OpenAI.Codex'
$nodePath = 'app/resources/codex-windows-sandbox-service.exe'
$extensionHost = 'app\resources\plugins\openai-bundled\plugins\chrome\extension-host\windows\x64\extension-host.exe'
$sigCheck = Join-Path $PSScriptRoot '../Test-OfficialPackageSignature.ps1'
$target = "OpenAI.Codex_${Version}_x64__2p2nqsd0c76g0"
$phase = 'registration-query'

function Read-Registration([string]$Expected) {
    $items = @(Get-AppxPackage -Name OpenAI.Codex -PackageTypeFilter Main)
    if ($items.Count -ne 1 -or $items[0].PackageFamilyName -cne $family -or
        $items[0].PackageFullName -cne $Expected -or $items[0].Status -ne 'Ok' -or
        $items[0].SignatureKind -ne 'Store' -or $items[0].InstallLocation -ine (Join-Path $storeRoot $Expected)) {
        throw 'unexpected-registered-store-package'
    }
    return $items[0]
}

function Read-Service([string]$Package) {
    $service = Get-CimInstance Win32_Service -Filter "Name='$serviceName'"
    $expected = Join-Path (Join-Path $storeRoot $Package) ($nodePath.Replace('/', '\'))
    if ($null -eq $service -or $service.PathName.Trim('"') -ine $expected) { throw 'service-image-drift' }
    return $service
}

function Read-Archive([string]$InstalledPayload) {
    if ($Archive -notmatch '^D:[\\/]' -or [IO.Path]::GetExtension($Archive) -ine '.msix') { throw 'invalid-archive-path' }
    $file = Get-Item -LiteralPath $Archive
    if ($file.PSIsContainer -or $file.Length -le 0 -or $file.Length -gt 4GB -or
        ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'invalid-archive-path' }
    for ($directory = $file.Directory; $null -ne $directory; $directory = $directory.Parent) {
        if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'invalid-archive-path' }
    }
    $archiveHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($ArchiveSha256 -and $ArchiveSha256 -cne $archiveHash) { throw 'rollback-archive-drift' }
    $signature = Get-AuthenticodeSignature -LiteralPath $file.FullName
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.GetNameInfo('SimpleName', $false) -cne $publisher) {
        throw 'archive-signature-invalid'
    }
    $zip = [IO.Compression.ZipFile]::OpenRead($file.FullName)
    try {
        $manifests = @($zip.Entries | Where-Object FullName -CEQ 'AppxManifest.xml')
        if ($manifests.Count -ne 1 -or $manifests[0].Length -gt 2MB) { throw 'invalid-archive-manifest' }
        $reader = [IO.StreamReader]::new($manifests[0].Open())
        try { [xml]$manifest = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $identity = $manifest.Package.Identity
        if ($identity.Name -cne 'OpenAI.Codex' -or $identity.ProcessorArchitecture -cne 'x64' -or
            $identity.Version -cne $Version -or $identity.Publisher -cne "CN=$publisher" -or $identity.ResourceId) {
            throw 'archive-identity-mismatch'
        }
        if ($InstalledPayload) {
            foreach ($name in @('AppxManifest.xml', 'AppxBlockMap.xml', 'AppxSignature.p7x', 'app/ChatGPT.exe')) {
                $entries = @($zip.Entries | Where-Object FullName -IEQ $name)
                if ($entries.Count -ne 1 -or $entries[0].Length -le 0) { throw 'archive-payload-incomplete' }
                $entry = $entries[0].Open()
                try { $expected = (Get-FileHash -InputStream $entry).Hash } finally { $entry.Dispose() }
                if ((Get-FileHash -LiteralPath (Join-Path $InstalledPayload $name)).Hash -cne $expected) {
                    throw 'archive-payload-mismatch'
                }
            }
        }
    } finally { $zip.Dispose() }
    return [ordered]@{sha256=$archiveHash; bytes=$file.Length; full_name=$target; signature='Valid'}
}

try {
    $result = [ordered]@{ok=$true; phase=$Mode; full_name=$target; version=$Version}
    if ($Mode -eq 'Proof') {
        $registered = Read-Registration $target
        $phase = 'rollback-archive-proof'
        $result.archive = Read-Archive $registered.InstallLocation
    } elseif ($Mode -in @('Register','Rollback')) {
        if (-not $CurrentVersion -or $CurrentVersion -eq $Version) { throw 'invalid-version-transition' }
        $current = "OpenAI.Codex_${CurrentVersion}_x64__2p2nqsd0c76g0"
        $null = Read-Registration $current
        if ($Mode -eq 'Rollback') {
            $phase = 'rollback-archive-proof'
            if (-not $ArchiveSha256 -or ([version]$Version -ge [version]$CurrentVersion)) { throw 'invalid-rollback-target' }
            $null = Read-Archive ''
        } else {
            $phase = 'stage-proof'
            $stage = & (Join-Path $PSScriptRoot 'Read-CodexStoreDeployment.ps1') -CurrentVersion $CurrentVersion | ConvertFrom-Json
            $matching = @($stage.offers | Where-Object { $_.full_name -ceq $target -and $_.stage_record })
            if (-not $stage.ok -or $matching.Count -ne 1 -or
                @($stage.offers | Where-Object { [version]$_.version -gt [version]$Version }).Count) {
                throw 'invalid-stage-target'
            }
        }
        $phase = 'quiesce-package'
        $service = Read-Service $current
        $prefix = (Join-Path $storeRoot $current) + '\'
        $packageProcesses = @(Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and $_.Id -ne $service.ProcessId })
        if (@($packageProcesses | Where-Object { $_.Path.Substring($prefix.Length) -ine $extensionHost }).Count) {
            throw 'unexpected-package-process'
        }
        $restoreService = $service.State -eq 'Running'
        try {
            if ($restoreService) {
                Stop-Service -Name $serviceName
                (Get-Service -Name $serviceName).WaitForStatus('Stopped',[timespan]::FromSeconds(15))
            } elseif ($service.State -ne 'Stopped') { throw 'service-not-idle' }
            foreach ($process in $packageProcesses) {
                $live = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
                if ($live -and $live.Path -ceq $process.Path -and $live.StartTime -eq $process.StartTime) {
                    Stop-Process -InputObject $live
                    if (-not $live.WaitForExit(5000)) { throw 'package-worker-still-running' }
                }
            }
            $null = Read-Registration $current
            $phase = 'appx-deployment'
            if ($Mode -eq 'Register') { Add-AppxPackage -MainPackage $target -Register }
            else { Add-AppxPackage -Path $Archive -ForceUpdateFromAnyVersion }
        } finally {
            if ($restoreService -and (Get-Service -Name $serviceName).Status -ne 'Running') {
                Start-Service -Name $serviceName
                (Get-Service -Name $serviceName).WaitForStatus('Running',[timespan]::FromSeconds(15))
            }
        }
    }
    if ($Mode -ne 'Proof') {
        $phase = 'verify-installed-signature'
        $null = Read-Registration $target
        $signatures = @(& $sigCheck -Channel StoreMain -PackageFullName $target)
        if ($signatures.Count -ne 1 -or $signatures[0].verified -ne $true) { throw 'registered-signature-invalid' }
        $phase = 'verify-service-image'
        $service = Read-Service $target
        if ($service.State -ne 'Running' -or $service.ProcessId -le 0) { throw 'service-not-running' }
        $result.signature_verified = $true
    }
    ConvertTo-Json -InputObject $result -Depth 4 -Compress
} catch {
    [ordered]@{ok=$false; phase=$Mode; status=$phase; hresult=$_.Exception.HResult} | ConvertTo-Json -Compress
    exit 1
}
