Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Reuse the repository's D-drive and reparse policy; never execute the external icon tool.
. (Join-Path $PSScriptRoot 'CodexHostSafety.ps1')
Add-Type -AssemblyName System.Drawing
$script:Contexts = @{}

function Read-MsixManifestAssets {
    param([string]$PackageRoot, [string]$PackageName, [string]$Publisher, [string]$ApplicationId)
    $manifestPath = Join-Path $PackageRoot 'AppxManifest.xml'
    # Verify the bounded package-relative read before opening the manifest. This
    # also prevents the isolated fixture provider from reading through redirected inputs.
    $manifestItem = Get-Item -LiteralPath $manifestPath -Force
    $packageItem = Get-Item -LiteralPath $PackageRoot -Force
    if ($manifestItem.PSIsContainer -or (($manifestItem.Attributes -bor $packageItem.Attributes) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'MSIX manifest/package reparse point rejected.' }
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [Xml.XmlReader]::Create($manifestPath, $settings)
    try { $document = [Xml.XmlDocument]::new(); $document.XmlResolver = $null; $document.Load($reader) }
    finally { $reader.Dispose() }
    $identity = $document.SelectSingleNode('/*[local-name()="Package"]/*[local-name()="Identity"]')
    if ($null -eq $identity -or $identity.GetAttribute('Name') -cne $PackageName -or $identity.GetAttribute('Publisher') -cne $Publisher) {
        throw 'MSIX manifest identity mismatch.'
    }
    $apps = @($document.SelectNodes('/*[local-name()="Package"]/*[local-name()="Applications"]/*[local-name()="Application"]') | Where-Object { $_.GetAttribute('Id') -ceq $ApplicationId })
    if ($apps.Count -ne 1 -or $ApplicationId -notmatch '^[A-Za-z0-9.]+$') { throw 'MSIX application identity mismatch.' }
    $visual = $apps[0].SelectSingleNode('*[local-name()="VisualElements"]')
    if ($null -eq $visual) { throw 'MSIX VisualElements missing.' }
    $logo = $visual.GetAttribute('Square44x44Logo')
    if ([string]::IsNullOrWhiteSpace($logo) -or [IO.Path]::IsPathRooted($logo) -or $logo -match '[:*?]' -or @($logo -split '[\\/]' | Where-Object { $_ -in @('..', '.') }).Count -gt 0) {
        throw 'Invalid manifest logo asset path.'
    }
    $logoPath = [IO.Path]::GetFullPath((Join-Path $PackageRoot $logo))
    if (-not (Test-CodexHookPathWithin -Path $logoPath -ParentPath $PackageRoot) -or [IO.Path]::GetExtension($logoPath) -ine '.png') { throw 'Invalid manifest logo asset path.' }
    $directory = [IO.Path]::GetDirectoryName($logoPath)
    $stem = [IO.Path]::GetFileNameWithoutExtension($logoPath)
    $candidates = @(Get-ChildItem -LiteralPath $directory -File -Filter ($stem + '.targetsize-*.png'))
    $suffix = if (@($candidates | Where-Object Name -like '*_altform-unplated.png').Count -gt 0) { '_altform-unplated' } else { '' }
    $pattern = '^' + [regex]::Escape($stem) + '\.targetsize-([0-9]+)' + $suffix + '\.png$'
    $assets = @(foreach ($file in $candidates) {
        if ($file.Name -notmatch $pattern) { continue }
        $size = [int]$Matches[1]
        if ($size -lt 16 -or $size -gt 256) { continue }
        # Asset ancestry is checked from the registered package root, which may be on C:.
        $current = $file.FullName
        while ((Test-CodexHookPathWithin -Path $current -ParentPath $PackageRoot)) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'MSIX asset reparse point rejected.' }
            if ($current -ieq $PackageRoot) { break }
            $current = [IO.Path]::GetDirectoryName($current)
        }
        $bitmap = [Drawing.Bitmap]::new($file.FullName)
        try {
            if ($bitmap.Width -ne $size -or $bitmap.Height -ne $size -or $bitmap.RawFormat.Guid -ne [Drawing.Imaging.ImageFormat]::Png.Guid) {
                throw ('Invalid MSIX PNG dimensions or format: ' + $file.Name)
            }
        } finally { $bitmap.Dispose() }
        [pscustomobject]@{ size = $size; path = $file.FullName; sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash }
    })
    $assets = @($assets | Sort-Object size)
    foreach ($required in @(16,32,48,256)) {
        if (@($assets | Where-Object size -eq $required).Count -ne 1) { throw ('Required MSIX targetsize PNG missing or ambiguous: ' + $required) }
    }
    [pscustomobject]@{ manifestPath = $manifestPath; manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash; assets = $assets }
}

function Get-MsixRegisteredPackage {
    param([string]$PackageName, [string]$PackageFamilyName)
    if ($PackageName -notmatch '^[A-Za-z0-9.-]+$' -or $PackageFamilyName -notmatch '^[A-Za-z0-9.-]+_[a-z0-9]{13}$') { throw 'Invalid explicit MSIX package identity.' }
    $packages = @(Get-AppxPackage -Name $PackageName | Where-Object Name -CEQ $PackageName)
    if ($packages.Count -ne 1) { throw 'Expected exactly one registered MSIX package.' }
    $package = $packages[0]
    if ($package.PackageFamilyName -cne $PackageFamilyName -or $package.Status.ToString() -cne 'Ok' -or $package.SignatureKind.ToString() -cne 'Store' -or $package.IsDevelopmentMode) {
        throw 'Official Store package identity/status/signature mismatch.'
    }
    if ([string]::IsNullOrWhiteSpace($package.InstallLocation) -or [string]::IsNullOrWhiteSpace($package.Publisher)) { throw 'Registered MSIX package location/publisher missing.' }
    return $package
}

function Register-MsixContext {
    param([hashtable]$Record)
    $context = [pscustomobject]@{ contextId = [guid]::NewGuid().ToString('N'); source = $Record.source; packageName = $Record.packageName; packageFamilyName = $Record.packageFamilyName; applicationId = $Record.applicationId }
    $Record.snapshot = Read-MsixManifestAssets -PackageRoot $Record.packageRoot -PackageName $Record.packageName -Publisher $Record.publisher -ApplicationId $Record.applicationId
    $Record.handle = $context
    $script:Contexts[$context.contextId] = $Record
    return $context
}

function Get-MsixInstalledPackageContext {
    <# Production provider. No fixture/provider override is accepted by the CLI. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PackageName, [Parameter(Mandatory)][string]$PackageFamilyName, [Parameter(Mandatory)][string]$ApplicationId)
    $package = Get-MsixRegisteredPackage -PackageName $PackageName -PackageFamilyName $PackageFamilyName
    Register-MsixContext @{ source = 'InstalledPackage'; packageName = $PackageName; packageFamilyName = $PackageFamilyName; applicationId = $ApplicationId; publisher = $package.Publisher; packageRoot = [IO.Path]::GetFullPath($package.InstallLocation); packageFullName = $package.PackageFullName; fixtureRoot = $null }
}

function New-MsixShortcutFixtureContext {
    <# Supported fixture provider: fixed non-production identity and writes confined to its GUID directory. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FixtureRoot)
    $root = Assert-CodexHookDPath -Value $FixtureRoot -Name 'FixtureRoot'
    Assert-CodexHookNoReparseAncestor -Path $root -Name 'FixtureRoot'
    if ([IO.Path]::GetFileName($root) -cnotmatch '^msix-shortcut-fixture-[a-f0-9]{32}$') { throw 'FixtureRoot must be an isolated msix-shortcut-fixture GUID directory.' }
    Register-MsixContext @{ source = 'Fixture'; packageName = 'Fixture.MsixShortcut'; packageFamilyName = 'Fixture.MsixShortcut_0000000000000'; applicationId = 'App'; publisher = 'CN=MsixShortcutFixture'; packageRoot = (Join-Path $root 'package'); fixtureRoot = $root }
}

function Get-MsixContextRecord {
    param([object]$PackageContext)
    if ($null -eq $PackageContext -or $null -eq $PackageContext.PSObject.Properties['contextId'] -or -not $script:Contexts.ContainsKey([string]$PackageContext.contextId)) { throw 'Unvalidated MSIX package context.' }
    $record = $script:Contexts[[string]$PackageContext.contextId]
    if (-not [object]::ReferenceEquals($record.handle, $PackageContext)) { throw 'Unvalidated MSIX package context.' }
    if ($record.source -eq 'InstalledPackage') {
        $live = Get-MsixRegisteredPackage -PackageName $record.packageName -PackageFamilyName $record.packageFamilyName
        if ($live.PackageFullName -cne $record.packageFullName -or [IO.Path]::GetFullPath($live.InstallLocation) -ine $record.packageRoot -or $live.Publisher -cne $record.publisher) { throw 'Registered MSIX package identity drift.' }
    } else { Assert-CodexHookNoReparseAncestor -Path $record.fixtureRoot -Name 'FixtureRoot' }
    $current = Read-MsixManifestAssets -PackageRoot $record.packageRoot -PackageName $record.packageName -Publisher $record.publisher -ApplicationId $record.applicationId
    if (($current | ConvertTo-Json -Depth 5 -Compress) -cne ($record.snapshot | ConvertTo-Json -Depth 5 -Compress)) { throw 'MSIX manifest/assets drift since validation.' }
    return $record
}

function Initialize-MsixShortcutShell {
    if ('UnifiedEnvironment.MsixShortcutShell' -as [type]) { return }
    # Unicode IShellLink/IPersistFile keeps existing property stores and data blocks;
    # no WScript ANSI path conversion, and only SetIconLocation is used for existing links.
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
namespace UnifiedEnvironment {
    [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellLinkW {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int length, IntPtr data, uint flags);
        void GetIDList(out IntPtr idList);
        void SetIDList(IntPtr idList);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder text, int length);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string text);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int length);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string path);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder text, int length);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string text);
        void GetHotkey(out short hotkey);
        void SetHotkey(short hotkey);
        void GetShowCmd(out int command);
        void SetShowCmd(int command);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int length, out int index);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string path, int index);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path, uint reserved);
        void Resolve(IntPtr window, uint flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string path);
    }
    public sealed class MsixShortcutState {
        public string Target, Arguments, Description, WorkingDirectory, IconPath;
        public short Hotkey;
        public int ShowCommand, IconIndex;
    }
    public static class MsixShortcutShell {
        static object Open(string path) {
            object link = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("00021401-0000-0000-C000-000000000046")));
            try { if (path != null) ((IPersistFile)link).Load(path, 0); return link; }
            catch { Marshal.FinalReleaseComObject(link); throw; }
        }
        public static MsixShortcutState Read(string path) {
            object value = Open(path);
            try {
                var link = (IShellLinkW)value;
                var text = new StringBuilder(32768);
                var state = new MsixShortcutState();
                link.GetPath(text, text.Capacity, IntPtr.Zero, 4); state.Target = text.ToString(); text.Clear();
                link.GetArguments(text, text.Capacity); state.Arguments = text.ToString(); text.Clear();
                link.GetDescription(text, text.Capacity); state.Description = text.ToString(); text.Clear();
                link.GetWorkingDirectory(text, text.Capacity); state.WorkingDirectory = text.ToString(); text.Clear();
                link.GetIconLocation(text, text.Capacity, out state.IconIndex); state.IconPath = text.ToString();
                link.GetHotkey(out state.Hotkey); link.GetShowCmd(out state.ShowCommand);
                return state;
            } finally { Marshal.FinalReleaseComObject(value); }
        }
        public static void SetIcon(string path, string icon) {
            object value = Open(path);
            try { ((IShellLinkW)value).SetIconLocation(icon, 0); ((IPersistFile)value).Save(path, true); }
            finally { Marshal.FinalReleaseComObject(value); }
        }
        public static void Create(string path, string target, string arguments, string icon) {
            object value = Open(null);
            try {
                var link = (IShellLinkW)value;
                link.SetPath(target); link.SetArguments(arguments); link.SetIconLocation(icon, 0);
                ((IPersistFile)value).Save(path, true);
            } finally { Marshal.FinalReleaseComObject(value); }
        }
        [DllImport("shell32.dll", CharSet=CharSet.Unicode)]
        public static extern void SHChangeNotify(uint eventId, uint flags, string item1, IntPtr item2);
    }
}
'@
}

function ConvertTo-MsixDibIcon {
    param([object[]]$Assets)
    $entries = @(foreach ($asset in $Assets) {
        $size = [int]$asset.size
        $source = [Drawing.Bitmap]::new([string]$asset.path)
        $bitmap = [Drawing.Bitmap]::new($size, $size, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
        try {
            $graphics = [Drawing.Graphics]::FromImage($bitmap)
            try {
                $graphics.CompositingMode = [Drawing.Drawing2D.CompositingMode]::SourceCopy
                $graphics.DrawImageUnscaled($source, 0, 0)
            } finally { $graphics.Dispose() }
            $pixels = [byte[]]::new($size * $size * 4)
            $data = $bitmap.LockBits([Drawing.Rectangle]::new(0, 0, $size, $size), [Drawing.Imaging.ImageLockMode]::ReadOnly, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
            try {
                for ($row = 0; $row -lt $size; $row++) {
                    [Runtime.InteropServices.Marshal]::Copy([IntPtr]($data.Scan0.ToInt64() + $row * $data.Stride), $pixels, ($size - 1 - $row) * $size * 4, $size * 4)
                }
            } finally { $bitmap.UnlockBits($data) }
        } finally { $source.Dispose(); $bitmap.Dispose() }
        $mask = [byte[]]::new([int]([math]::Ceiling($size / 32.0) * 4 * $size))
        $stream = [IO.MemoryStream]::new()
        $writer = [IO.BinaryWriter]::new($stream)
        try {
            $writer.Write([uint32]40); $writer.Write([int32]$size); $writer.Write([int32]($size * 2))
            $writer.Write([uint16]1); $writer.Write([uint16]32); $writer.Write([uint32]0)
            $writer.Write([uint32]($pixels.Length + $mask.Length))
            $writer.Write([int32]0); $writer.Write([int32]0); $writer.Write([uint32]0); $writer.Write([uint32]0)
            $writer.Write($pixels); $writer.Write($mask); $writer.Flush()
            [pscustomobject]@{ size = $size; data = $stream.ToArray() }
        } finally { $writer.Dispose(); $stream.Dispose() }
    })
    $stream = [IO.MemoryStream]::new()
    $writer = [IO.BinaryWriter]::new($stream)
    try {
        $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$entries.Count)
        $offset = 6 + 16 * $entries.Count
        foreach ($entry in $entries) {
            $dimension = if ($entry.size -eq 256) { [byte]0 } else { [byte]$entry.size }
            $writer.Write($dimension); $writer.Write($dimension); $writer.Write([byte]0); $writer.Write([byte]0)
            $writer.Write([uint16]1); $writer.Write([uint16]32)
            $writer.Write([uint32]$entry.data.Length); $writer.Write([uint32]$offset)
            $offset += $entry.data.Length
        }
        foreach ($entry in $entries) { $writer.Write([byte[]]$entry.data) }
        $writer.Flush()
        return ,$stream.ToArray()
    } finally { $writer.Dispose(); $stream.Dispose() }
}

function Get-MsixOutputSnapshot {
    param([string]$Path)
    $snapshot = Get-CodexHookHandleBoundFileSnapshot -Path $Path -Name 'Shortcut output' -AllowedExactPaths @($Path)
    if ($snapshot.probe.state -eq 'missing') { return $null }
    if (-not $snapshot.probe.safeToRead -or -not $snapshot.probe.finalPathVerified) { throw 'Shortcut output is not a verified ordinary file.' }
    [pscustomobject]@{ bytes = $snapshot.bytes; hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($snapshot.bytes)); identity = ($snapshot.probe.identity -join ':') }
}

function Assert-MsixOutputUnchanged {
    param([string]$Path, [object]$Before)
    $current = Get-MsixOutputSnapshot -Path $Path
    if (($null -eq $Before) -ne ($null -eq $current)) { throw 'Shortcut output appeared/disappeared during operation.' }
    if ($null -ne $Before -and ($current.hash -cne $Before.hash -or $current.identity -cne $Before.identity)) { throw 'Shortcut output identity/hash drift during operation.' }
}

function Assert-MsixShortcutIdentity {
    param([object]$State, [string]$Target, [string]$Arguments)
    if ($State.Target -ine $Target -or $State.Arguments -cne $Arguments) { throw 'Existing shortcut target/AUMID identity mismatch; refusing overwrite.' }
}

function Assert-MsixShortcutPreserved {
    param([object]$Before, [object]$After)
    foreach ($field in @('Target','Arguments','Description','WorkingDirectory','Hotkey','ShowCommand')) {
        if ($Before.$field -cne $After.$field) { throw ('Shortcut setting changed unexpectedly: ' + $field) }
    }
}

function Invoke-MsixDesktopShortcut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$PackageContext,
        [Parameter(Mandatory)][string]$ShortcutPath,
        [Parameter(Mandatory)][string]$IconPath,
        [ValidateSet('Plan','Apply')][string]$Mode = 'Plan'
    )
    $record = Get-MsixContextRecord -PackageContext $PackageContext
    $shortcut = Assert-CodexHookDPath -Value $ShortcutPath -Name 'ShortcutPath'
    $icon = Assert-CodexHookDPath -Value $IconPath -Name 'IconPath'
    foreach ($path in @($shortcut, $icon)) {
        Assert-CodexHookNoReparseAncestor -Path $path -Name 'Shortcut output'
        if ($record.source -eq 'Fixture' -and -not (Test-CodexHookPathWithin -Path $path -ParentPath $record.fixtureRoot)) { throw 'Fixture output escapes isolated root.' }
        if (-not (Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($path)) -PathType Container)) { throw 'Shortcut output parent must already exist.' }
        if (Test-CodexHookPathWithin -Path $path -ParentPath $record.packageRoot) { throw 'Shortcut output must not modify MSIX package assets.' }
    }
    if ([IO.Path]::GetExtension($shortcut) -ine '.lnk' -or [IO.Path]::GetExtension($icon) -ine '.ico' -or $icon.Contains(',')) { throw 'Expected explicit .lnk and comma-free .ico output paths.' }
    $beforeLink = Get-MsixOutputSnapshot -Path $shortcut
    $beforeIcon = Get-MsixOutputSnapshot -Path $icon
    $target = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)) 'explorer.exe'
    $aumid = $record.packageFamilyName + '!' + $record.applicationId
    $arguments = 'shell:AppsFolder\' + $aumid
    $beforeState = $null
    if ($null -ne $beforeLink) {
        Initialize-MsixShortcutShell
        $beforeState = [UnifiedEnvironment.MsixShortcutShell]::Read($shortcut)
        Assert-MsixShortcutIdentity -State $beforeState -Target $target -Arguments $arguments
    }
    # An existing ICO belongs to this operation only if the identity-checked link already uses it.
    if ($null -ne $beforeIcon -and ($null -eq $beforeState -or $beforeState.IconPath -ine $icon -or $beforeState.IconIndex -ne 0)) { throw 'Existing icon target is not owned by this shortcut; refusing overwrite.' }
    $result = [ordered]@{
        mode = $Mode; readOnly = ($Mode -eq 'Plan'); source = $record.source; aumid = $aumid
        packageName = $record.packageName; packageFamilyName = $record.packageFamilyName
        manifestSha256 = $record.snapshot.manifestHash; sizes = @($record.snapshot.assets.size)
        assets = @($record.snapshot.assets | ForEach-Object { [pscustomobject]@{ size = $_.size; path = $_.path; sha256 = $_.sha256 } }); shortcutPath = $shortcut; iconPath = $icon
        target = $target; arguments = $arguments; before = $beforeState
        rollbackShortcut = $null; rollbackIcon = $null
    }
    if ($Mode -eq 'Plan') { return [pscustomobject]$result }
    Initialize-MsixShortcutShell
    $iconBytes = ConvertTo-MsixDibIcon -Assets $record.snapshot.assets
    $operation = [guid]::NewGuid().ToString('N')
    $linkStage = Join-Path ([IO.Path]::GetDirectoryName($shortcut)) ('.msix-' + $operation + '.lnk')
    $iconStage = Join-Path ([IO.Path]::GetDirectoryName($icon)) ('.msix-' + $operation + '.ico')
    $linkBackup = $shortcut + '.msix-' + $operation + '.before.lnk'
    $iconBackup = $icon + '.msix-' + $operation + '.before.ico'
    $iconCommitted = $false; $linkCommitted = $false
    $iconHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($iconBytes))
    $linkHash = $null
    try {
        # CreateNew prevents overwriting a stage belonging to another operation.
        $file = [IO.File]::Open($iconStage, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $file.Write($iconBytes); $file.Flush($true) } finally { $file.Dispose() }
        if ($null -ne $beforeLink) {
            [IO.File]::Copy($shortcut, $linkStage, $false)
            [UnifiedEnvironment.MsixShortcutShell]::SetIcon($linkStage, $icon)
        } else { [UnifiedEnvironment.MsixShortcutShell]::Create($linkStage, $target, $arguments, $icon) }
        $afterState = [UnifiedEnvironment.MsixShortcutShell]::Read($linkStage)
        Assert-MsixShortcutIdentity -State $afterState -Target $target -Arguments $arguments
        if ($null -ne $beforeState) { Assert-MsixShortcutPreserved -Before $beforeState -After $afterState }
        if ($afterState.IconPath -ine $icon -or $afterState.IconIndex -ne 0) { throw 'Shortcut icon postcondition failed.' }
        $linkHash = (Get-MsixOutputSnapshot -Path $linkStage).hash
        [void](Get-MsixContextRecord -PackageContext $PackageContext)
        Assert-MsixOutputUnchanged -Path $icon -Before $beforeIcon
        Assert-MsixOutputUnchanged -Path $shortcut -Before $beforeLink
        if ($null -eq $beforeIcon) { [IO.File]::Move($iconStage, $icon) }
        else { [IO.File]::Replace($iconStage, $icon, $iconBackup) }
        $iconCommitted = $true
        Assert-MsixOutputUnchanged -Path $shortcut -Before $beforeLink
        if ($null -eq $beforeLink) { [IO.File]::Move($linkStage, $shortcut) }
        else { [IO.File]::Replace($linkStage, $shortcut, $linkBackup) }
        $linkCommitted = $true
        $saved = [UnifiedEnvironment.MsixShortcutShell]::Read($shortcut)
        Assert-MsixShortcutIdentity -State $saved -Target $target -Arguments $arguments
        if ($null -ne $beforeState) { Assert-MsixShortcutPreserved -Before $beforeState -After $saved }
        if ($saved.IconPath -ine $icon -or $saved.IconIndex -ne 0 -or (Get-MsixOutputSnapshot -Path $icon).hash -cne $iconHash) { throw 'Published shortcut/icon postcondition failed.' }
        [UnifiedEnvironment.MsixShortcutShell]::SHChangeNotify(0x00002000, 0x00001005, $shortcut, [IntPtr]::Zero)
        $result.after = $saved
        $result.iconSha256 = $iconHash
        $result.shortcutSha256 = (Get-MsixOutputSnapshot -Path $shortcut).hash
        $result.rollbackShortcut = if ($null -ne $beforeLink) { $linkBackup } else { $null }
        $result.rollbackIcon = if ($null -ne $beforeIcon) { $iconBackup } else { $null }
        $result.shellNotification = 'SHCNE_UPDATEITEM / SHCNF_PATHW | SHCNF_FLUSH'
        return [pscustomobject]$result
    } catch {
        $cause = $_
        try {
            # Restore only files published by this operation; refuse to clobber concurrent work.
            if ($linkCommitted) {
                if ((Get-MsixOutputSnapshot -Path $shortcut).hash -cne $linkHash) { throw 'Shortcut changed before rollback.' }
                if ($null -eq $beforeLink) { [IO.File]::Delete($shortcut) }
                else { [IO.File]::Copy($linkBackup, $linkStage, $false); [IO.File]::Replace($linkStage, $shortcut, [NullString]::Value) }
            }
            if ($iconCommitted) {
                if ((Get-MsixOutputSnapshot -Path $icon).hash -cne $iconHash) { throw 'Icon changed before rollback.' }
                if ($null -eq $beforeIcon) { [IO.File]::Delete($icon) }
                else { [IO.File]::Copy($iconBackup, $iconStage, $false); [IO.File]::Replace($iconStage, $icon, [NullString]::Value) }
            }
            if ($linkCommitted) { [UnifiedEnvironment.MsixShortcutShell]::SHChangeNotify(0x00002000, 0x00001005, $shortcut, [IntPtr]::Zero) }
        } catch { throw ('MSIX shortcut failed; rollback incomplete. Backups: ' + $linkBackup + '; ' + $iconBackup + '. Rollback error: ' + $_.Exception.Message + '. Original error: ' + $cause.Exception.Message) }
        throw ('MSIX shortcut apply failed; published changes rolled back: ' + $cause.Exception.Message)
    } finally {
        # These exact sibling stage paths were generated and created by this operation.
        foreach ($stage in @($linkStage, $iconStage)) { if ([IO.File]::Exists($stage)) { [IO.File]::Delete($stage) } }
    }
}

Export-ModuleMember -Function Get-MsixInstalledPackageContext, New-MsixShortcutFixtureContext, Invoke-MsixDesktopShortcut
