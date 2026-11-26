#Requires -Version 7.5
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Sync-AntigravityAddons.ps1')

$managedDirectory = 'D:\Apps\Google.Antigravity'
$legacyDirectory = 'C:\Users\Fixture\AppData\Local\Programs\antigravity'
$deployment = [pscustomobject]@{
    directory = $managedDirectory
    executablePath = "$managedDirectory\Antigravity.exe"
    uninstallerPath = "$managedDirectory\Uninstall Antigravity.exe"
    present = $true
    uninstallerPresent = $true
}
$desktop = [pscustomobject]@{ desktopRunning = $false; executablePaths = @(); pathUnverified = $false }
$views = @(foreach ($view in 'Registry32', 'Registry64') {
    [pscustomobject]@{
        view = $view
        readable = $true
        productKeyPresent = $true
        productInstallLocation = $legacyDirectory
        uninstallKeyPresent = $true
        uninstallInstallLocation = $managedDirectory
        uninstallString = '"D:\Apps\Google.Antigravity\Uninstall Antigravity.exe" /currentuser'
        quietUninstallString = '"D:\Apps\Google.Antigravity\Uninstall Antigravity.exe" /currentuser /S'
        machineRegistrationPresent = $false
    }
})

$result = Get-AntigravityUpdateTarget $deployment $views $desktop
if ($result.ready -or $result.productKeyMatchesDeployment -or -not $result.uninstallRegistrationMatchesDeployment) {
    throw 'D: in Add/Remove Programs must not hide the C: NSIS update target.'
}
foreach ($view in $result.registryViews) {
    if ($view.productReason -cne 'product-location-mismatch' -or $view.productInstallLocation -ine $legacyDirectory) {
        throw "The stale NSIS product path must be reported on $($view.view)."
    }
}
if ($result.running.desktopRunning -or $result.running.otherInstallationRunning -or $result.running.reason -cne 'desktop-not-running') {
    throw 'The absence of a visible desktop is not an installation mismatch.'
}

foreach ($view in $views) { $view.productInstallLocation = 'd:/apps/google.antigravity/' }
$result = Get-AntigravityUpdateTarget $deployment $views $desktop
if (-not $result.ready -or -not $result.productKeyMatchesDeployment -or
    -not $result.uninstallRegistrationMatchesDeployment -or $result.running.matchesDeployment) {
    throw 'Both matching views and a closed desktop must be ready, with no running path match reported.'
}

$desktop.desktopRunning = $true
$desktop.executablePaths = @($deployment.executablePath)
$result = Get-AntigravityUpdateTarget $deployment $views $desktop
if (-not $result.ready -or -not $result.running.matchesDeployment -or $result.running.otherInstallationRunning) {
    throw 'A running desktop on D: must match the managed deployment.'
}
$desktop.executablePaths += "$legacyDirectory\Antigravity.exe"
$result = Get-AntigravityUpdateTarget $deployment $views $desktop
if ($result.ready -or $result.running.matchesDeployment -or -not $result.running.otherInstallationRunning -or
    $result.running.reason -cne 'other-installation-running') {
    throw 'A second visible desktop from C: must be distinguished from the managed instance.'
}
$desktop.executablePaths = @()
$desktop.pathUnverified = $true
$result = Get-AntigravityUpdateTarget $deployment $views $desktop
if ($result.ready -or $result.running.reason -cne 'running-path-unverified' -or $result.running.otherInstallationRunning) {
    throw 'An unreadable process image must be reported as unverified.'
}
$desktop.desktopRunning = $false
$desktop.pathUnverified = $false

$views[0].productKeyPresent = $false
$views[0].productInstallLocation = $null
$views[1].productInstallLocation = 'D:\Fixture\..\Apps\Google.Antigravity'
$views[1].uninstallString = 'D:\Apps\Google.Antigravity\Uninstall Antigravity.exe /currentuser'
$result = Get-AntigravityUpdateTarget $deployment $views $desktop
if ($result.ready -or $result.productKeyMatchesDeployment -or $result.uninstallRegistrationMatchesDeployment -or
    $result.registryViews[0].productReason -cne 'product-key-missing' -or
    $result.registryViews[1].productReason -cne 'product-location-invalid' -or
    $result.registryViews[1].uninstallReason -cne 'uninstall-path-missing-or-invalid') {
    throw 'Missing product key, dot-segment install location and ambiguously unquoted uninstall command must fail closed.'
}

$views[0].productKeyPresent = $true
$views[0].productInstallLocation = $managedDirectory
$views[1].productInstallLocation = $managedDirectory
$views[1].uninstallString = '"C:\Fixture\Uninstall Antigravity.exe" /currentuser'
$views[1].machineRegistrationPresent = $true
$result = Get-AntigravityUpdateTarget $deployment $views $desktop
if ($result.ready -or -not $result.productKeyMatchesDeployment -or -not $result.machineRegistrationPresent -or
    $result.registryViews[1].uninstallReason -cne 'uninstall-path-mismatch') {
    throw 'Other-install uninstaller and machine-wide registration must be visible.'
}
$missing = Get-AntigravityDeployment ("D:\antigravity-missing-fixture-" + [guid]::NewGuid().ToString('N'))
if ($missing.present -or $missing.executableIssue -cne 'missing' -or $missing.appAsarIssue -cne 'missing') {
    throw 'Missing deployed artifacts must have explicit diagnostics.'
}

$tmpDirectory = if ([IO.Directory]::Exists('D:\agents\tmp')) { 'D:\agents\tmp' } else { 'D:\Codex\temp' }
$artifact = Join-Path $tmpDirectory ('antigravity-artifact-fixture-' + [guid]::NewGuid().ToString('N'))
if ((Get-AntigravityArtifactIssue $artifact) -cne 'missing' -or -not [IO.Directory]::Exists($tmpDirectory)) {
    throw 'Artifact fixture requires its ordinary D: temp directory.'
}
$exclusive = [IO.File]::Open($artifact, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    if ((Get-AntigravityArtifactIssue $artifact) -cne 'unreadable') { throw 'An exclusive file lock must yield unreadable.' }
} finally {
    $exclusive.Dispose()
    [IO.File]::Delete($artifact)
}

$regTestId = 'CodexAntigravityRegFixture-' + [guid]::NewGuid().ToString('N')
$testProductSubKey = "Software\$regTestId\Product"
$testUninstallSubKey = "Software\$regTestId\Uninstall"
$testRootSubKey = "Software\$regTestId"
try {
    foreach ($regView in 'Registry32', 'Registry64') {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, $regView)
        try {
            $pKey = $baseKey.CreateSubKey($testProductSubKey)
            $uKey = $baseKey.CreateSubKey($testUninstallSubKey)
            try {
                $pKey.SetValue('InstallLocation', $managedDirectory, [Microsoft.Win32.RegistryValueKind]::String)
                $uKey.SetValue('UninstallString', '"D:\Apps\Google.Antigravity\Uninstall Antigravity.exe" /currentuser', [Microsoft.Win32.RegistryValueKind]::String)
                $uKey.SetValue('QuietUninstallString', '"D:\Apps\Google.Antigravity\Uninstall Antigravity.exe" /currentuser /S', [Microsoft.Win32.RegistryValueKind]::String)
            } finally {
                $uKey.Dispose()
                $pKey.Dispose()
            }
        } finally {
            $baseKey.Dispose()
        }
    }

    $healedRows = @(Repair-AntigravityUninstallRegistration -Deployment $deployment -ProductSubKey $testProductSubKey -UninstallSubKey $testUninstallSubKey)
    if ($healedRows.Count -ne 2 -or ($healedRows.healed -notcontains $true) -or
        @($healedRows | Where-Object { $_.reason -notin @('healed', 'already-aligned') }).Count -ne 0) {
        throw 'Missing HKCU Uninstall InstallLocation must be healed across HKCU views when product and uninstaller match.'
    }
    foreach ($regView in 'Registry32', 'Registry64') {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, $regView)
        try {
            $uKey = $baseKey.OpenSubKey($testUninstallSubKey, $false)
            try {
                if ([string]$uKey.GetValue('InstallLocation') -ine $managedDirectory) {
                    throw "Healed InstallLocation missing in $regView."
                }
            } finally {
                $uKey.Dispose()
            }
        } finally {
            $baseKey.Dispose()
        }
    }
    $idempotentRows = @(Repair-AntigravityUninstallRegistration -Deployment $deployment -ProductSubKey $testProductSubKey -UninstallSubKey $testUninstallSubKey)
    if ($idempotentRows.Count -ne 2 -or ($idempotentRows.healed -contains $true) -or
        @($idempotentRows | Where-Object { $_.reason -cne 'already-aligned' }).Count -ne 0) {
        throw 'Aligned HKCU Uninstall InstallLocation must not be rewritten.'
    }

    foreach ($regView in 'Registry32', 'Registry64') {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, $regView)
        try {
            $pKey = $baseKey.OpenSubKey($testProductSubKey, $true)
            $uKey = $baseKey.OpenSubKey($testUninstallSubKey, $true)
            try {
                $uKey.DeleteValue('InstallLocation', $false)
                $pKey.SetValue('InstallLocation', $legacyDirectory, [Microsoft.Win32.RegistryValueKind]::String)
            } finally {
                $uKey.Dispose()
                $pKey.Dispose()
            }
        } finally {
            $baseKey.Dispose()
        }
    }
    $refusedRows = @(Repair-AntigravityUninstallRegistration -Deployment $deployment -ProductSubKey $testProductSubKey -UninstallSubKey $testUninstallSubKey)
    if (($refusedRows.healed -contains $true) -or ($refusedRows.reason -notcontains 'product-mismatch')) {
        throw 'Mismatched product InstallLocation must refuse Uninstall registry healing.'
    }
} finally {
    foreach ($regView in 'Registry32', 'Registry64') {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, $regView)
        try {
            $baseKey.DeleteSubKeyTree($testRootSubKey, $false)
        } finally {
            $baseKey.Dispose()
        }
    }
}

$syncScript = Join-Path $PSScriptRoot 'Sync-AntigravityAddons.ps1'
$reconcilerScript = Join-Path $PSScriptRoot 'reconcile-addons.mjs'
$pwshExe = Join-Path $PSHOME 'pwsh.exe'
$nodeCmd = if (Test-Path -LiteralPath 'D:\Codex\tools\bin\node.exe' -PathType Leaf) { 'D:\Codex\tools\bin\node.exe' } else { 'node' }

# Exercise Sync-AntigravityAddons.ps1 production default parameter path without any fixture target overrides.
$defaultStatusRaw = & $pwshExe -NoProfile -NonInteractive -File $syncScript -Mode Status
if ($LASTEXITCODE -ne 0) {
    throw "Production default Status invocation failed ($LASTEXITCODE)."
}
$defaultStatus = ($defaultStatusRaw | Out-String) | ConvertFrom-Json
if ($defaultStatus.mode -cne 'Status' -or $null -eq $defaultStatus.updateTarget) {
    throw 'Production default Status invocation returned an unexpected JSON shape.'
}
foreach ($scRow in @($defaultStatus.shortcuts)) {
    if (-not ($scRow.PSObject.Properties.Name -contains 'appUserModelId')) {
        throw 'Production default Get-ShortcutAudit row is missing appUserModelId.'
    }
}

# Regression: NSIS non-silent ExecShellAsUser launches LaunchAntigravity.exe (-Mode Apply) while PostQuit holds
# the reconcile mutex for >5s building the new version's ASAR. -Mode Apply must wait for PostQuit rather than
# timing out after 5s with skipped-busy and letting Antigravity lock the unpatched app.asar.
$handoffRoot = Join-Path $tmpDirectory ('antigravity-handoff-fixture-' + [guid]::NewGuid().ToString('N'))
$fixtureAppDir = Join-Path $handoffRoot 'app'
$fixtureResDir = Join-Path $fixtureAppDir 'resources'
$fixtureBinDir = Join-Path $fixtureResDir 'bin'
$fixtureBackupDir = Join-Path $handoffRoot 'backup'
$fixtureStateDir = Join-Path $handoffRoot 'state'
$fixtureEvidenceDir = Join-Path $handoffRoot 'evidence'
$fixtureAsar = Join-Path $fixtureResDir 'app.asar'
$fixtureLs = Join-Path $fixtureBinDir 'language_server.exe'
$fixtureMutexName = 'Local\AntigravityAddonsFixtureMutex-' + [guid]::NewGuid().ToString('N')

try {
    foreach ($d in @($fixtureBinDir, $fixtureBackupDir, $fixtureStateDir, $fixtureEvidenceDir)) {
        [void][IO.Directory]::CreateDirectory($d)
    }
    $buildAsarJs = @'
import fs from 'node:fs';
import { createHash } from 'node:crypto';
const outPath = process.argv[2];
const wslSrc = [
  '"use strict";',
  'const child_process = require("child_process");',
  'const fs = require("fs");',
  'const path = require("path");',
  'const { promisify } = require("util");',
  'const execFileAsync = promisify(child_process.execFile);',
  'exports.WSL_EXE = path.join(process.env.SystemRoot || "C:\\\\Windows", "System32", "wsl.exe");',
  'function isWslAvailable() { return process.platform === "win32" && fs.existsSync(exports.WSL_EXE); }',
  'function decodeWslOutput(buf) { return buf.includes(0) ? buf.toString("utf16le").replace(/^\\uFEFF/, "") : buf.toString("utf8"); }',
  'async function execWsl(args) {',
  '    const { stdout } = await execFileAsync(exports.WSL_EXE, args, {',
  '        encoding: "buffer",',
  '            timeout: 30000,',
  '        });',
  '        return decodeWslOutput(stdout);',
  '}',
  'async function listWslDistros() {',
  "    const output = await execWsl(['--list', '--verbose']);",
  '    return output.split(/\\r?\\n/).slice(1).map((line) => line.replace(/^\\*\\s*/, "").trim()).filter(Boolean).map((line) => {',
  '        const [name, state, version] = line.split(/\\s+/);',
  '        return { name, state, version: Number(version) };',
  '    }).filter((d) => d.version === 2 && !d.name.startsWith("docker-desktop"));',
  '}',
  'exports.listWslDistros = listWslDistros;',
].join('\n');
const files = {
  'package.json': Buffer.from('{"name":"antigravity","version":"2.99.5"}', 'utf8'),
  'dist/wsl.js': Buffer.from(wslSrc, 'utf8'),
};
const header = { files: {} };
const chunks = [];
let offset = 0;
for (const rel of Object.keys(files).sort()) {
  const data = files[rel];
  const parts = rel.split('/');
  const leaf = parts.pop();
  let dir = header.files;
  for (const p of parts) { if (!dir[p]) dir[p] = { files: {} }; dir = dir[p].files; }
  const digest = createHash('sha256').update(data).digest('hex');
  dir[leaf] = { size: data.length, offset: String(offset), integrity: { algorithm: 'SHA256', hash: digest, blockSize: 4194304, blocks: [digest] } };
  chunks.push(data);
  offset += data.length;
}
const hb = Buffer.from(JSON.stringify(header), 'utf8');
const pad = (hb.length + 3) & ~3;
const pre = Buffer.alloc(16 + pad, 0);
pre.writeUInt32LE(4, 0);
pre.writeUInt32LE(8 + pad, 4);
pre.writeUInt32LE(4 + pad, 8);
pre.writeUInt32LE(hb.length, 12);
hb.copy(pre, 16);
fs.writeFileSync(outPath, Buffer.concat([pre, ...chunks]));
'@
    $builderMjs = Join-Path $handoffRoot 'build-fixture-asar.mjs'
    [IO.File]::WriteAllText($builderMjs, $buildAsarJs, [Text.UTF8Encoding]::new($false))
    & $nodeCmd $builderMjs $fixtureAsar
    if ($LASTEXITCODE -ne 0) { throw 'Failed to synthesize fixture app.asar.' }
    [IO.File]::WriteAllText($fixtureLs, 'synthetic-ls-2.99.5', [Text.UTF8Encoding]::new($false))
    $officialAsarSha = (Get-FileHash -LiteralPath $fixtureAsar -Algorithm SHA256).Hash.ToLowerInvariant()

    # Exercise default -MutexName (omitted) on an isolated fixture build first, then reset to official bytes for contention test.
    $defaultMutexRun = & $pwshExe -NoProfile -NonInteractive -File $syncScript -Mode Apply -SkipShortcutHeal -SkipRegistrationHeal `
        -AppDir $fixtureAppDir -BackupDir $fixtureBackupDir -StateDir $fixtureStateDir -EvidenceRoot $fixtureEvidenceDir
    if ($LASTEXITCODE -ne 0) { throw "Default-mutex fixture Apply failed ($LASTEXITCODE)." }
    $defaultMutexJson = ($defaultMutexRun | Out-String) | ConvertFrom-Json
    if ($defaultMutexJson.reconcile.status -cne 'applied') {
        throw "Expected default-mutex fixture Apply to apply cleanly, got $($defaultMutexJson.reconcile.status)."
    }
    Copy-Item -LiteralPath (Join-Path $fixtureBackupDir 'app.asar.2.99.5.original') -Destination $fixtureAsar -Force
    Remove-Item -LiteralPath (Join-Path $fixtureStateDir 'active-build.json') -Force

    # Contention test: PostQuit stand-in holds mutex for ~6.2s (> old 5s timeout) and reconciles before releasing.
    $holderScript = Join-Path $handoffRoot 'holder.ps1'
    $readyFile = Join-Path $handoffRoot 'holder.ready'
    $holderSrc = @"
`$ErrorActionPreference = 'Stop'
`$m = [Threading.Mutex]::new(`$false, '$fixtureMutexName')
[void]`$m.WaitOne(10000)
try {
    [IO.File]::WriteAllText('$readyFile', 'locked')
    Start-Sleep -Milliseconds 5600
    `$out = & '$nodeCmd' '$reconcilerScript' 'reconcile' '--apply' '--app-dir' '$fixtureAppDir' '--backup-dir' '$fixtureBackupDir' '--state-root' '$fixtureStateDir' '--evidence-root' '$fixtureEvidenceDir'
    if (`$LASTEXITCODE -ne 0) { throw "Holder reconcile failed (`$LASTEXITCODE): `$out" }
} finally {
    try { `$m.ReleaseMutex() } catch {}
    `$m.Dispose()
}
"@
    [IO.File]::WriteAllText($holderScript, $holderSrc, [Text.UTF8Encoding]::new($false))

    $holderPsi = [Diagnostics.ProcessStartInfo]::new($pwshExe)
    $holderPsi.UseShellExecute = $false
    $holderPsi.RedirectStandardOutput = $true
    $holderPsi.RedirectStandardError = $true
    foreach ($a in @('-NoProfile', '-NonInteractive', '-File', $holderScript)) { $holderPsi.ArgumentList.Add($a) }
    $holderProc = [Diagnostics.Process]::Start($holderPsi)
    try {
        $readyDeadline = [datetime]::UtcNow.AddSeconds(8)
        while (-not (Test-Path -LiteralPath $readyFile -PathType Leaf) -and [datetime]::UtcNow -lt $readyDeadline) {
            Start-Sleep -Milliseconds 50
        }
        if (-not (Test-Path -LiteralPath $readyFile -PathType Leaf)) {
            throw 'Mutex holder did not acquire the fixture mutex in time.'
        }

        $applyRaw = & $pwshExe -NoProfile -NonInteractive -File $syncScript -Mode Apply -SkipShortcutHeal -SkipRegistrationHeal `
            -AppDir $fixtureAppDir -BackupDir $fixtureBackupDir -StateDir $fixtureStateDir -EvidenceRoot $fixtureEvidenceDir -MutexName $fixtureMutexName
        if ($LASTEXITCODE -ne 0) {
            throw "Concurrent -Mode Apply failed ($LASTEXITCODE)."
        }
        $applyJson = ($applyRaw | Out-String) | ConvertFrom-Json
        $asarShaAtLauncherResume = (Get-FileHash -LiteralPath $fixtureAsar -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($applyJson.PSObject.Properties['status']?.Value -ceq 'skipped-busy' -or $asarShaAtLauncherResume -ceq $officialAsarSha) {
            throw "Concurrent -Mode Apply returned before PostQuit finished patching app.asar (status=$($applyJson.PSObject.Properties['status']?.Value), asarStillUnpatched=$($asarShaAtLauncherResume -ceq $officialAsarSha))."
        }
        if ($applyJson.reconcile.status -cne 'up-to-date') {
            throw "Expected waiting -Mode Apply to observe up-to-date after PostQuit release, got $($applyJson.reconcile.status)."
        }
        $holderOut = $holderProc.StandardOutput.ReadToEnd()
        $holderErr = $holderProc.StandardError.ReadToEnd()
        [void]$holderProc.WaitForExit(10000)
        if ($holderProc.ExitCode -ne 0) {
            throw "Mutex holder exited $($holderProc.ExitCode): $holderErr $holderOut"
        }
    } finally {
        if (-not $holderProc.HasExited) { try { $holderProc.Kill() } catch {} }
        $holderProc.Dispose()
    }

    # Verify PostQuit duplicate-relaunch suppression when LaunchAntigravity (or Antigravity) is already waiting/running.
    $compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $fakeLauncherExe = Join-Path $fixtureBackupDir 'LaunchAntigravity.exe'
    $fakeLauncherCs = Join-Path $handoffRoot 'FakeLauncher.cs'
    [IO.File]::WriteAllText($fakeLauncherCs, 'using System.Threading; class P { static void Main() { Thread.Sleep(15000); } }', [Text.UTF8Encoding]::new($false))
    & $compiler /nologo /target:exe /out:$fakeLauncherExe $fakeLauncherCs
    if ($LASTEXITCODE -ne 0) { throw 'Failed to compile FakeLauncher.exe.' }

    $fakeLauncherProc = [Diagnostics.Process]::Start([Diagnostics.ProcessStartInfo]::new($fakeLauncherExe))
    try {
        Start-Sleep -Milliseconds 150
        if (-not (Test-LauncherProcessRunning -ExpectedLauncherPath $fakeLauncherExe)) {
            throw 'Test-LauncherProcessRunning did not detect the waiting LaunchAntigravity.exe process.'
        }
    } finally {
        if (-not $fakeLauncherProc.HasExited) { try { $fakeLauncherProc.Kill(); [void]$fakeLauncherProc.WaitForExit(3000) } catch {} }
        $fakeLauncherProc.Dispose()
    }
    if (Test-LauncherProcessRunning -ExpectedLauncherPath $fakeLauncherExe) {
        throw 'Test-LauncherProcessRunning reported true after LaunchAntigravity.exe exited.'
    }
    if ((Test-LauncherProcessRunning) -isnot [bool]) {
        throw 'Production default Test-LauncherProcessRunning must return a boolean.'
    }

    # Verify Get-ShortcutAudit heals both missing AUMID (pinned running window) and legacy electron.app.Antigravity AUMID,
    # while leaving unrelated third-party shortcuts untouched.
    $shortcutFixtureDir = Join-Path $handoffRoot 'shortcut-fixtures'
    [void][IO.Directory]::CreateDirectory($shortcutFixtureDir)
    $fakeAppExe = Join-Path $fixtureAppDir 'Antigravity.exe'
    [IO.File]::WriteAllText($fakeAppExe, 'fake-antigravity-exe', [Text.UTF8Encoding]::new($false))
    $otherExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $lnkPinnedBare = Join-Path $shortcutFixtureDir 'Antigravity.lnk'
    $lnkLegacyAumid = Join-Path $shortcutFixtureDir 'Google Antigravity.lnk'
    $lnkUnrelated = Join-Path $shortcutFixtureDir 'Unrelated.lnk'
    $wshFixture = New-Object -ComObject WScript.Shell
    try {
        $s1 = $wshFixture.CreateShortcut($lnkPinnedBare)
        $s1.TargetPath = $fakeAppExe
        $s1.Save()

        $s2 = $wshFixture.CreateShortcut($lnkLegacyAumid)
        $s2.TargetPath = $fakeLauncherExe
        $s2.WorkingDirectory = $fixtureAppDir
        $s2.IconLocation = "$fakeAppExe,0"
        $s2.Save()

        $s3 = $wshFixture.CreateShortcut($lnkUnrelated)
        $s3.TargetPath = $otherExe
        $s3.Save()
    } finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($wshFixture)
    }
    Initialize-ShortcutShellInterop
    [AntigravityAddons.ShortcutShellInterop]::HealShortcut($lnkLegacyAumid, $fakeLauncherExe, $fixtureAppDir, $fakeAppExe, 0, 'electron.app.Antigravity')

    $auditBefore = Get-ShortcutAudit -CandidatePathsForTest @($lnkPinnedBare, $lnkLegacyAumid, $lnkUnrelated) `
        -LauncherPath $fakeLauncherExe -TargetAppDir $fixtureAppDir -TargetAppExe $fakeAppExe
    if ($auditBefore.Count -ne 3 -or
        -not $auditBefore[0].needsHeal -or $null -ne $auditBefore[0].appUserModelId -or
        -not $auditBefore[1].needsHeal -or $auditBefore[1].appUserModelId -cne 'electron.app.Antigravity' -or
        $auditBefore[2].needsHeal) {
        throw 'Get-ShortcutAudit pre-heal classification did not flag bare/legacy AUMID shortcuts and spare unrelated shortcut.'
    }

    $auditHealed = Get-ShortcutAudit -Heal -CandidatePathsForTest @($lnkPinnedBare, $lnkLegacyAumid, $lnkUnrelated) `
        -LauncherPath $fakeLauncherExe -TargetAppDir $fixtureAppDir -TargetAppExe $fakeAppExe
    if (-not $auditHealed[0].healed -or $auditHealed[0].target -ine $fakeLauncherExe -or $auditHealed[0].appUserModelId -cne 'com.google.antigravity' -or
        -not $auditHealed[1].healed -or $auditHealed[1].target -ine $fakeLauncherExe -or $auditHealed[1].appUserModelId -cne 'com.google.antigravity' -or
        $auditHealed[2].healed -or $auditHealed[2].target -ine $otherExe) {
        throw 'Get-ShortcutAudit -Heal did not align managed shortcuts to LaunchAntigravity.exe + com.google.antigravity.'
    }

    $auditIdempotent = Get-ShortcutAudit -Heal -CandidatePathsForTest @($lnkPinnedBare, $lnkLegacyAumid, $lnkUnrelated) `
        -LauncherPath $fakeLauncherExe -TargetAppDir $fixtureAppDir -TargetAppExe $fakeAppExe
    if (($auditIdempotent.healed -contains $true) -or ($auditIdempotent.needsHeal -contains $true)) {
        throw 'Get-ShortcutAudit -Heal was not idempotent on aligned shortcuts.'
    }

    # Verify governed Deploy-AntigravityAddons.ps1 default Check path (zero seam overrides) and isolated Check/Apply/Check cycle.
    $deployScript = Join-Path $PSScriptRoot 'Deploy-AntigravityAddons.ps1'
    $PSNativeCommandUseErrorActionPreference = $false
    $defaultDeployRaw = & $pwshExe -NoProfile -NonInteractive -File $deployScript -Mode Check
    $defaultDeployExit = $LASTEXITCODE
    $PSNativeCommandUseErrorActionPreference = $true
    $defaultDeployJson = ($defaultDeployRaw | Out-String) | ConvertFrom-Json
    if ($defaultDeployJson.mode -cne 'Check' -or $defaultDeployJson.status -notin @('matched', 'drift', 'target-root-absent')) {
        throw "Unexpected default Deploy-AntigravityAddons Check status: $($defaultDeployJson.status) (exit=$defaultDeployExit)."
    }

    $deployToolsTarget = Join-Path $handoffRoot 'deploy-tools'
    $deployLauncherTarget = Join-Path $handoffRoot 'deploy-local'
    $deployEvidenceRoot = Join-Path $handoffRoot 'deploy-evidence'
    foreach ($d in @($deployToolsTarget, $deployLauncherTarget, $deployEvidenceRoot)) {
        [void][IO.Directory]::CreateDirectory($d)
    }
    $PSNativeCommandUseErrorActionPreference = $false
    $preCheckRaw = & $pwshExe -NoProfile -NonInteractive -File $deployScript -Mode Check `
        -ToolsTargetRoot $deployToolsTarget -LauncherTargetRoot $deployLauncherTarget -EvidenceRoot $deployEvidenceRoot
    $preCheckExit = $LASTEXITCODE
    $PSNativeCommandUseErrorActionPreference = $true
    $preCheckJson = ($preCheckRaw | Out-String) | ConvertFrom-Json
    if ($preCheckExit -ne 1 -or $preCheckJson.status -cne 'drift') {
        throw "Expected initial empty target Check to report drift (exit=1), got exit=$preCheckExit status=$($preCheckJson.status)."
    }

    $applyDeployRaw = & $pwshExe -NoProfile -NonInteractive -File $deployScript -Mode Apply `
        -ToolsTargetRoot $deployToolsTarget -LauncherTargetRoot $deployLauncherTarget -EvidenceRoot $deployEvidenceRoot
    if ($LASTEXITCODE -ne 0) { throw "Isolated Deploy-AntigravityAddons Apply failed ($LASTEXITCODE)." }
    $applyDeployJson = ($applyDeployRaw | Out-String) | ConvertFrom-Json
    if ($applyDeployJson.status -cne 'deployed' -or $applyDeployJson.writtenFiles -lt 8 -or
        -not (Test-Path -LiteralPath (Join-Path $deployLauncherTarget 'LaunchAntigravity.exe') -PathType Leaf)) {
        throw 'Isolated Deploy-AntigravityAddons Apply did not materialize all targets and LaunchAntigravity.exe.'
    }

    $postCheckRaw = & $pwshExe -NoProfile -NonInteractive -File $deployScript -Mode Check `
        -ToolsTargetRoot $deployToolsTarget -LauncherTargetRoot $deployLauncherTarget -EvidenceRoot $deployEvidenceRoot
    if ($LASTEXITCODE -ne 0) { throw "Post-Apply Check failed ($LASTEXITCODE)." }
    $postCheckJson = ($postCheckRaw | Out-String) | ConvertFrom-Json
    if ($postCheckJson.status -cne 'matched' -or $postCheckJson.changedFiles -ne 0) {
        throw "Expected post-Apply Check to report matched with 0 changedFiles, got $($postCheckJson.status) ($($postCheckJson.changedFiles))."
    }
} finally {
    if (Test-Path -LiteralPath $handoffRoot) {
        Remove-Item -LiteralPath $handoffRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output 'Antigravity update target fixtures passed.'
