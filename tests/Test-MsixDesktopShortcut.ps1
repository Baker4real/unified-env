param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$FixtureParent = 'D:/Codex/temp'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

if (-not [IO.Path]::IsPathFullyQualified($FixtureParent) -or [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($FixtureParent)) -ine 'D:\') { throw 'Fixtures must be on D:.' }
$ancestor = [IO.Path]::GetFullPath($FixtureParent)
while ($ancestor) {
    if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Fixture parent reparse point rejected.' }
    $ancestor = [IO.Path]::GetDirectoryName($ancestor)
}
$fixture = Join-Path $FixtureParent ('msix-shortcut-fixture-' + [guid]::NewGuid().ToString('N'))
$packageRoot = Join-Path $fixture 'package'
$assets = Join-Path $packageRoot 'Assets'
[void][IO.Directory]::CreateDirectory($assets)
Add-Type -AssemblyName System.Drawing
$sizes = @(16,20,24,30,32,36,40,44,48,60,64,72,80,96,256)
foreach ($size in $sizes) {
    $bitmap = [Drawing.Bitmap]::new($size, $size)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        # Distinct per-size artwork catches accidental upscaling of a single source frame.
        $sourceColor = switch ($size) {
            48 { [Drawing.Color]::FromArgb(255, 32, 160, 64) }
            96 { [Drawing.Color]::FromArgb(255, 160, 32, 192) }
            default { [Drawing.Color]::FromArgb(255, 32, 96, 208) }
        }
        $graphics.Clear($sourceColor)
        $graphics.FillRectangle([Drawing.Brushes]::OrangeRed, 0, 0, ($size / 2), ($size / 2))
        $bitmap.Save((Join-Path $assets ('Logo.targetsize-' + $size + '_altform-unplated.png')), [Drawing.Imaging.ImageFormat]::Png)
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
}
$manifest = @'
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10" xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10">
  <Identity Name="Fixture.MsixShortcut" Publisher="CN=MsixShortcutFixture" Version="1.0.0.0" />
  <Applications><Application Id="App" Executable="app.exe" EntryPoint="Windows.FullTrustApplication">
    <uap:VisualElements DisplayName="Fixture" Square44x44Logo="Assets\Logo.png" Square150x150Logo="Assets\Other.png" />
  </Application></Applications>
</Package>
'@
[IO.File]::WriteAllText((Join-Path $packageRoot 'AppxManifest.xml'), $manifest)
Import-Module (Join-Path $ProjectRoot 'scripts/lib/MsixShortcutIcon.psm1') -Force -DisableNameChecking
$context = New-MsixShortcutFixtureContext -FixtureRoot $fixture
$shortcut = Join-Path $fixture 'fixture 中文.lnk'
$icon = Join-Path $fixture 'fixture.ico'
$plan = Invoke-MsixDesktopShortcut -PackageContext $context -ShortcutPath $shortcut -IconPath $icon
Assert-True ($plan.mode -eq 'Plan' -and $plan.readOnly) 'Default operation must be a read-only plan.'
Assert-True (($plan.sizes -join ',') -eq ($sizes -join ',')) 'Plan must use all official-layout targetsize PNGs, including 256.'
Assert-True ($plan.aumid -ceq 'Fixture.MsixShortcut_0000000000000!App') 'Manifest application identity must determine AUMID.'
Assert-True (-not (Test-Path -LiteralPath $shortcut) -and -not (Test-Path -LiteralPath $icon)) 'Planning must not create shortcut or icon.'
Write-Output ('PASS plan-multisize-readonly fixture=' + $fixture)

$plan.assets[0].sha256 = 'caller-mutated-plan'
$secondPlan = Invoke-MsixDesktopShortcut -PackageContext $context -ShortcutPath $shortcut -IconPath $icon
Assert-True ($secondPlan.assets[0].sha256 -ne 'caller-mutated-plan') 'Returned diagnostics must not mutate validated package context.'
Write-Output 'PASS public-context-isolation'

$result = Invoke-MsixDesktopShortcut -PackageContext $context -ShortcutPath $shortcut -IconPath $icon -Mode Apply
Assert-True ($result.mode -eq 'Apply' -and -not $result.readOnly) 'Apply must create the requested fixture shortcut and ICO.'
$bytes = [IO.File]::ReadAllBytes($icon)
Assert-True ([BitConverter]::ToUInt16($bytes, 2) -eq 1 -and [BitConverter]::ToUInt16($bytes, 4) -eq 15) 'ICO must contain 15 native-size frames.'
foreach ($index in 0..14) {
    $entry = 6 + 16 * $index
    $size = if ($bytes[$entry] -eq 0) { 256 } else { [int]$bytes[$entry] }
    $offset = [BitConverter]::ToUInt32($bytes, $entry + 12)
    Assert-True ($size -eq $sizes[$index] -and [BitConverter]::ToUInt32($bytes, $offset) -eq 40) 'ICO frames must be sorted DIB entries, not PNG blobs.'
    Assert-True ([BitConverter]::ToInt32($bytes, $offset + 4) -eq $size -and [BitConverter]::ToInt32($bytes, $offset + 8) -eq 2 * $size -and [BitConverter]::ToUInt16($bytes, $offset + 14) -eq 32) 'DIB dimensions and 32-bit depth must be valid.'
    $topLeft = $offset + 40 + ($size - 1) * $size * 4
    Assert-True (($bytes[$topLeft..($topLeft + 3)] -join ',') -eq '0,69,255,255') 'DIB must preserve official PNG BGRA pixels and bottom-up orientation.'
    $sourcePixel = $topLeft + [int]($size * 0.75) * 4
    $nativeColor = switch ($size) { 48 { '64,160,32,255' }; 96 { '192,32,160,255' }; default { '208,96,32,255' } }
    Assert-True (($bytes[$sourcePixel..($sourcePixel + 3)] -join ',') -ceq $nativeColor) 'Each DIB frame must preserve its distinct native targetsize PNG rather than upscaling one source.'
}
$stream = [IO.File]::OpenRead($icon)
try {
    $decoded = [Drawing.Icon]::new($stream, 256, 256)
    try { $preview = $decoded.ToBitmap(); $preview.Save((Join-Path $fixture 'dib-256.png'), [Drawing.Imaging.ImageFormat]::Png); $preview.Dispose() }
    finally { $decoded.Dispose() }
} finally { $stream.Dispose() }
Write-Output 'PASS apply-multisize-dib-parse-and-decode'

$entrypoint = Join-Path $ProjectRoot 'scripts/New-MsixDesktopShortcut.ps1'
Assert-True (Test-Path -LiteralPath $entrypoint -PathType Leaf) 'Repository must provide the production-only shortcut entrypoint.'
$entryCommand = Get-Command -Name $entrypoint
Assert-True (-not $entryCommand.Parameters.ContainsKey('FixtureRoot') -and -not $entryCommand.Parameters.ContainsKey('PackageContext') -and -not $entryCommand.Parameters.ContainsKey('PackageProvider')) 'Production CLI must not accept a fixture or package-provider override.'
Write-Output 'PASS production-entrypoint-no-fixture-override'

# An independent Windows Shell consumer, not the encoder or a mocked icon decoder.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential)] public struct MsixTestIconSize { public int cx; public int cy; }
[ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMsixTestImageFactory { [PreserveSig] int GetImage(MsixTestIconSize size, uint flags, out IntPtr bitmap); }
public static class MsixTestShellRenderer {
    [DllImport("shell32.dll", CharSet=CharSet.Unicode, PreserveSig=true)]
    static extern int SHCreateItemFromParsingName(string path, IntPtr bind, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IMsixTestImageFactory factory);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr value);
    public static IntPtr Render(string path, int size) {
        var iid = new Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b");
        IMsixTestImageFactory factory;
        Marshal.ThrowExceptionForHR(SHCreateItemFromParsingName(path, IntPtr.Zero, ref iid, out factory));
        try {
            IntPtr bitmap;
            Marshal.ThrowExceptionForHR(factory.GetImage(new MsixTestIconSize { cx=size, cy=size }, 4, out bitmap));
            return bitmap;
        } finally { Marshal.FinalReleaseComObject(factory); }
    }
}
'@
foreach ($size in @(48,96,256)) {
    $handle = [MsixTestShellRenderer]::Render($shortcut, $size)
    Assert-True ($handle -ne [IntPtr]::Zero) 'Windows Shell must return an actual shortcut bitmap.'
    try {
        $image = [Drawing.Bitmap]::FromHbitmap($handle)
        try {
            Assert-True ($image.Width -eq $size -and $image.Height -eq $size) 'Shell render must retain requested dimensions.'
            $pixel = $image.GetPixel([int]($size * 0.75), [int]($size * 0.25))
            # The Shell may select a larger frame and downscale (observed for 96).
            # Native-source fidelity is independently asserted against every DIB above.
            $actualColor = @($pixel.R,$pixel.G,$pixel.B) -join ','
            Assert-True ($actualColor -in @('32,160,64','160,32,192','32,96,208')) 'Shell must render source artwork, not a generic or corrupt icon.'
            $image.Save((Join-Path $fixture ('shell-' + $size + '.png')), [Drawing.Imaging.ImageFormat]::Png)
        } finally { $image.Dispose() }
    } finally { [void][MsixTestShellRenderer]::DeleteObject($handle) }
}
Write-Output 'PASS windows-shell-shortcut-render-48-96-256'

function Assert-Rejected([string]$Name, [scriptblock]$Action, [string]$Pattern) {
    $errorMessage = $null
    try { & $Action | Out-Null } catch { $errorMessage = $_.Exception.Message }
    if ($null -eq $errorMessage -or $errorMessage -notlike $Pattern) { Write-Output ('FAIL reject-' + $Name + ' actual=' + $errorMessage) }
    Assert-True ($null -ne $errorMessage -and $errorMessage -like $Pattern) ($Name + ' must reject with expected reason; actual=' + $errorMessage)
    Write-Output ('PASS reject-' + $Name + ' reason=' + $errorMessage)
}
function Get-Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }

# Preserve non-icon fields, including a hotkey/show command that naive recreation loses.
$asciiShortcut = Join-Path $fixture 'existing.lnk'
[IO.File]::Copy($shortcut, $asciiShortcut)
$com = New-Object -ComObject WScript.Shell
$link = $com.CreateShortcut($asciiShortcut)
$link.Description = 'User description retained'
$link.WorkingDirectory = $fixture
$link.Hotkey = 'CTRL+ALT+F9'
$link.WindowStyle = 3
$link.Save()
$beforeBytesHash = Get-Hash $asciiShortcut
$beforeIconHash = Get-Hash $icon
$updated = Invoke-MsixDesktopShortcut -PackageContext $context -ShortcutPath $asciiShortcut -IconPath $icon -Mode Apply
$readback = $com.CreateShortcut($asciiShortcut)
Assert-True ($readback.Description -ceq 'User description retained' -and $readback.WorkingDirectory -ieq $fixture -and $readback.Hotkey -ceq 'Alt+Ctrl+F9' -and $readback.WindowStyle -eq 3) 'Existing shortcut settings must survive icon update.'
Assert-True ((Get-Hash $updated.rollbackShortcut) -ceq $beforeBytesHash -and (Get-Hash $updated.rollbackIcon) -ceq $beforeIconHash) 'Successful update must retain byte-exact reversible backups.'
Write-Output 'PASS existing-settings-and-byte-exact-backups'

$goodLinkHash = Get-Hash $asciiShortcut
$canonicalIconBytes = [IO.File]::ReadAllBytes($icon)
# A valid old ICO may contain trailing bytes. Make old and replacement hashes differ
# so a missing rollback cannot accidentally pass by publishing identical icon bytes.
[IO.File]::WriteAllBytes($icon, ($canonicalIconBytes + [byte[]]@(0x6f,0x6c,0x64)))
$goodIconHash = Get-Hash $icon
Assert-True ($goodIconHash -cne $updated.iconSha256) 'Rollback negative control requires distinct old and new bytes.'
$lock = [IO.File]::Open($asciiShortcut, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try {
    Assert-Rejected 'publish-failure-rollback' { Invoke-MsixDesktopShortcut -PackageContext $context -ShortcutPath $asciiShortcut -IconPath $icon -Mode Apply } '*published changes rolled back*'
} finally { $lock.Dispose() }
Assert-True ((Get-Hash $asciiShortcut) -ceq $goodLinkHash -and (Get-Hash $icon) -ceq $goodIconHash) 'Failure publishing the link must restore original icon and preserve the original link bytes.'
Write-Output 'PASS failed-publish-restores-original-bytes'

$unknownIcon = Join-Path $fixture 'unknown.ico'
[IO.File]::WriteAllText($unknownIcon, 'user-owned-unknown-icon')
$unknownHash = Get-Hash $unknownIcon
Assert-Rejected 'unknown-icon' { Invoke-MsixDesktopShortcut -PackageContext $context -ShortcutPath $asciiShortcut -IconPath $unknownIcon -Mode Apply } '*not owned*'
Assert-True ((Get-Hash $unknownIcon) -ceq $unknownHash) 'Unknown icon output must not be overwritten.'
$link = $com.CreateShortcut($asciiShortcut)
$link.Arguments = 'shell:AppsFolder\Another.Package_0000000000000!App'
$link.Save()
$driftHash = Get-Hash $asciiShortcut
Assert-Rejected 'shortcut-identity' { Invoke-MsixDesktopShortcut -PackageContext $context -ShortcutPath $asciiShortcut -IconPath $icon -Mode Apply } '*identity mismatch*'
Assert-True ((Get-Hash $asciiShortcut) -ceq $driftHash -and (Get-Hash $icon) -ceq $goodIconHash) 'Identity drift must preserve both files.'
$link.Arguments = $result.arguments
$link.TargetPath = Join-Path $env:WINDIR 'System32/notepad.exe'
$link.Save()
Assert-Rejected 'shortcut-target' { Invoke-MsixDesktopShortcut -PackageContext $context -ShortcutPath $asciiShortcut -IconPath $icon -Mode Apply } '*identity mismatch*'
[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($com)

Assert-Rejected 'C-drive-output' { Invoke-MsixDesktopShortcut -PackageContext $context -ShortcutPath 'C:/fixture.lnk' -IconPath $icon } '*D:*'
Assert-Rejected 'fixture-output-escape' { Invoke-MsixDesktopShortcut -PackageContext $context -ShortcutPath (Join-Path $FixtureParent 'escaped.lnk') -IconPath $icon -Mode Apply } '*escapes isolated root*'
Assert-Rejected 'unvalidated-context' { Invoke-MsixDesktopShortcut -PackageContext ([pscustomobject]@{contextId=$context.contextId; source='InstalledPackage'}) -ShortcutPath $shortcut -IconPath $icon -Mode Apply } '*Unvalidated*'
$junction = Join-Path $fixture 'junction'
[void](New-Item -ItemType Junction -Path $junction -Target $assets)
Assert-Rejected 'reparse-output' { Invoke-MsixDesktopShortcut -PackageContext $context -ShortcutPath (Join-Path $junction 'redirected.lnk') -IconPath $icon -Mode Apply } '*reparse*'
Assert-Rejected 'ADS-output' { Invoke-MsixDesktopShortcut -PackageContext $context -ShortcutPath ($shortcut + ':stream') -IconPath $icon } '*ADS*'

$png256 = Join-Path $assets 'Logo.targetsize-256_altform-unplated.png'
$png256Bytes = [IO.File]::ReadAllBytes($png256)
[IO.File]::Delete($png256)
Assert-Rejected 'missing-256' { New-MsixShortcutFixtureContext -FixtureRoot $fixture } '*256*'
[IO.File]::WriteAllBytes($png256, $png256Bytes)
$png32 = Join-Path $assets 'Logo.targetsize-32_altform-unplated.png'
$png32Bytes = [IO.File]::ReadAllBytes($png32)
[IO.File]::Copy((Join-Path $assets 'Logo.targetsize-16_altform-unplated.png'), $png32, $true)
Assert-Rejected 'wrong-asset-dimensions' { New-MsixShortcutFixtureContext -FixtureRoot $fixture } '*dimensions*'
[IO.File]::WriteAllBytes($png32, $png32Bytes)
$manifestPath = Join-Path $packageRoot 'AppxManifest.xml'
[IO.File]::WriteAllText($manifestPath, $manifest.Replace('Assets\Logo.png', '..\outside.png'))
Assert-Rejected 'manifest-asset-path' { New-MsixShortcutFixtureContext -FixtureRoot $fixture } '*asset path*'
[IO.File]::WriteAllText($manifestPath, $manifest.Replace('Fixture.MsixShortcut', 'OpenAI.Codex'))
Assert-Rejected 'fixture-production-identity' { New-MsixShortcutFixtureContext -FixtureRoot $fixture } '*identity mismatch*'
[IO.File]::WriteAllText($manifestPath, $manifest + "`n")
Assert-Rejected 'validated-context-drift' { Invoke-MsixDesktopShortcut -PackageContext $context -ShortcutPath $shortcut -IconPath $icon -Mode Apply } '*drift*'
[IO.File]::WriteAllText($manifestPath, $manifest)
Assert-True ((Get-Hash $shortcut) -ceq $result.shortcutSha256 -and (Get-Hash $icon) -ceq $goodIconHash) 'Rejected assets/paths/contexts must not mutate published files.'
# Even a fixture manifest with valid identity may not redirect through a reparse point.
$manifestCopy = Join-Path $fixture 'valid-manifest.xml'
[IO.File]::Copy($manifestPath, $manifestCopy)
[IO.File]::Delete($manifestPath)
[void](New-Item -ItemType SymbolicLink -Path $manifestPath -Target $manifestCopy)
Assert-Rejected 'reparse-manifest' { New-MsixShortcutFixtureContext -FixtureRoot $fixture } '*reparse*'
[IO.File]::WriteAllText((Join-Path $fixture 'result.json'), ([pscustomobject]@{
    status = 'PASS'; source = 'isolated D-drive fixture'; sizes = $sizes
    shellRenderSizes = @(48,96,256); renderer = 'Windows IShellItemImageFactory ICONONLY'
    rollbackVerified = $true; rollbackNegativeControl = 'different old icon bytes plus actual Windows sharing lock on shortcut'
    shortcutBackup = $updated.rollbackShortcut; iconBackup = $updated.rollbackIcon
    productionApplyExecuted = $false; explorerRestarted = $false; iconCacheDeleted = $false
    completedAt = [datetimeoffset]::Now.ToString('o')
} | ConvertTo-Json -Depth 4))
Write-Output ('PASS all-msix-shortcut-fixtures evidence=' + $fixture)
