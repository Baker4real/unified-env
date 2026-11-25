#Requires -Version 7.5
<#
.SYNOPSIS
Check or deploy the managed Antigravity addons reconciler and desktop launcher.
.DESCRIPTION
Check is read-only and returns exit 1 on drift or missing target roots. Apply compiles
LaunchAntigravity.exe from LaunchAntigravity.cs inside a D-drive evidence directory,
backs up prior files, atomically replaces the allowlist, verifies SHA-256 readback,
and writes manifest.json without requiring file deletions.
#>
[CmdletBinding()]
param(
    [ValidateSet('Check', 'Apply')]
    [string]$Mode = 'Check',
    [string]$AddonsSourceRoot = $PSScriptRoot,
    [string]$LauncherSourcePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'antigravity\LaunchAntigravity.cs'),
    [string]$ToolsTargetRoot = 'D:\Codex\tools\antigravity-addons',
    [string]$LauncherTargetRoot = 'D:\Apps\Google.Antigravity.Local',
    [string]$EvidenceRoot = 'D:\agents\run-evidence\antigravity-addons'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8

function Resolve-OrdinaryDPath([string]$PathValue, [string]$Label) {
    if (-not [IO.Path]::IsPathFullyQualified($PathValue)) {
        throw "$Label must be an absolute D drive path: $PathValue"
    }
    $full = [IO.Path]::GetFullPath($PathValue)
    if (-not $full.StartsWith('D:\', [StringComparison]::OrdinalIgnoreCase) -or $full.Length -le 3 -or $full.Substring(2).Contains(':')) {
        throw "$Label must resolve to an ordinary D drive path: $PathValue"
    }
    return $full.TrimEnd('\')
}

function Assert-NoReparseChain([string]$PathValue) {
    $cur = $PathValue
    while (-not [string]::IsNullOrEmpty($cur)) {
        $item = $null
        try { $item = Get-Item -LiteralPath $cur -Force -ErrorAction Stop }
        catch { if ($_.CategoryInfo.Category -ne 'ObjectNotFound') { throw } }
        if ($null -ne $item) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse point is not allowed on deployment path: $cur"
            }
            if ($cur -ne $PathValue -and -not $item.PSIsContainer) {
                throw "Deployment ancestor is not a directory: $cur"
            }
        }
        $cur = [IO.Path]::GetDirectoryName($cur)
    }
}

function Get-LowerSha256([string]$FilePath) {
    return (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash.ToLowerInvariant()
}

$addonsSrc = Resolve-OrdinaryDPath $AddonsSourceRoot 'AddonsSourceRoot'
$launcherSrc = Resolve-OrdinaryDPath $LauncherSourcePath 'LauncherSourcePath'
$toolsDst = Resolve-OrdinaryDPath $ToolsTargetRoot 'ToolsTargetRoot'
$launcherDst = Resolve-OrdinaryDPath $LauncherTargetRoot 'LauncherTargetRoot'
$evRoot = Resolve-OrdinaryDPath $EvidenceRoot 'EvidenceRoot'

foreach ($p in @($addonsSrc, $launcherSrc, $toolsDst, $launcherDst, $evRoot)) {
    Assert-NoReparseChain $p
}
if (-not (Test-Path -LiteralPath $addonsSrc -PathType Container)) {
    throw "AddonsSourceRoot does not exist: $addonsSrc"
}
if (-not (Test-Path -LiteralPath $launcherSrc -PathType Leaf)) {
    throw "LauncherSourcePath does not exist: $launcherSrc"
}

$addonsAllowlist = @(
    'reconcile-addons.mjs',
    'Sync-AntigravityAddons.ps1',
    'Deploy-AntigravityAddons.ps1',
    'post-quit-reconcile.vbs',
    'README.md',
    'test-reconcile-addons.mjs',
    'Test-AntigravityUpdateTarget.ps1'
)

if ($Mode -eq 'Check') {
    $toolsPresent = Test-Path -LiteralPath $toolsDst -PathType Container
    $launcherDirPresent = Test-Path -LiteralPath $launcherDst -PathType Container
    if (-not $toolsPresent -or -not $launcherDirPresent) {
        $absentReport = [pscustomobject]@{
            schemaVersion = 1
            mode = 'Check'
            status = 'target-root-absent'
            toolsTargetPresent = $toolsPresent
            launcherTargetPresent = $launcherDirPresent
            changedFiles = 0
            files = @()
        }
        $absentReport | ConvertTo-Json -Depth 6 -Compress
        exit 1
    }

    $records = @()
    foreach ($rel in $addonsAllowlist) {
        $s = Join-Path $addonsSrc $rel
        $t = Join-Path $toolsDst $rel
        Assert-NoReparseChain $s
        Assert-NoReparseChain $t
        if (-not (Test-Path -LiteralPath $s -PathType Leaf)) { throw "Missing allowlisted source: $s" }
        $sHash = Get-LowerSha256 $s
        $tExists = Test-Path -LiteralPath $t -PathType Leaf
        $tHash = if ($tExists) { Get-LowerSha256 $t } else { $null }
        $records += [pscustomobject]@{
            target = $t
            sourceSha256 = $sHash
            targetSha256 = $tHash
            status = $(if ($sHash -ceq $tHash) { 'matched' } elseif ($tExists) { 'different' } else { 'missing' })
        }
    }

    $dstCs = Join-Path $launcherDst 'LaunchAntigravity.cs'
    $dstExe = Join-Path $launcherDst 'LaunchAntigravity.exe'
    Assert-NoReparseChain $dstCs
    Assert-NoReparseChain $dstExe
    $csSrcHash = Get-LowerSha256 $launcherSrc
    $csExists = Test-Path -LiteralPath $dstCs -PathType Leaf
    $csDstHash = if ($csExists) { Get-LowerSha256 $dstCs } else { $null }
    $records += [pscustomobject]@{
        target = $dstCs
        sourceSha256 = $csSrcHash
        targetSha256 = $csDstHash
        status = $(if ($csSrcHash -ceq $csDstHash) { 'matched' } elseif ($csExists) { 'different' } else { 'missing' })
    }
    $exeExists = Test-Path -LiteralPath $dstExe -PathType Leaf
    $exeHash = if ($exeExists) { Get-LowerSha256 $dstExe } else { $null }
    $records += [pscustomobject]@{
        target = $dstExe
        sourceSha256 = $null
        targetSha256 = $exeHash
        status = $(if ($exeExists -and ($csSrcHash -ceq $csDstHash)) { 'present-aligned-source' } elseif ($exeExists) { 'stale-source' } else { 'missing' })
    }

    $drifted = @($records | Where-Object { $_.status -notin @('matched', 'present-aligned-source') })
    $checkOut = [pscustomobject]@{
        schemaVersion = 1
        mode = 'Check'
        status = $(if ($drifted.Count -eq 0) { 'matched' } else { 'drift' })
        changedFiles = $drifted.Count
        files = $records
    }
    $checkOut | ConvertTo-Json -Depth 6 -Compress
    if ($drifted.Count -ne 0) { exit 1 }
    exit 0
}

if (-not (Test-Path -LiteralPath $toolsDst -PathType Container)) {
    throw "ToolsTargetRoot does not exist: $toolsDst"
}
if (-not (Test-Path -LiteralPath $launcherDst -PathType Container)) {
    throw "LauncherTargetRoot does not exist: $launcherDst"
}

$stamp = [datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
$runDir = Join-Path $evRoot ("deploy-" + $stamp)
$backupDir = Join-Path $runDir 'backups'
[void][IO.Directory]::CreateDirectory($backupDir)

$csc = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$candidateExe = Join-Path $runDir 'LaunchAntigravity.candidate.exe'
& $csc /nologo /target:winexe /platform:x64 /r:System.Windows.Forms.dll "/out:$candidateExe" $launcherSrc
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $candidateExe -PathType Leaf)) {
    throw "LaunchAntigravity.exe compilation failed ($LASTEXITCODE)."
}

$plan = @()
foreach ($rel in $addonsAllowlist) {
    $plan += @{
        src = (Join-Path $addonsSrc $rel)
        dst = (Join-Path $toolsDst $rel)
        bak = (Join-Path $backupDir ("tools-" + ($rel -replace '[\\/]', '_')))
    }
}
$plan += @{
    src = $launcherSrc
    dst = (Join-Path $launcherDst 'LaunchAntigravity.cs')
    bak = (Join-Path $backupDir 'LaunchAntigravity.cs.bak')
}
$plan += @{
    src = $candidateExe
    dst = (Join-Path $launcherDst 'LaunchAntigravity.exe')
    bak = (Join-Path $backupDir 'LaunchAntigravity.exe.bak')
}

$deployed = @()
$writtenCount = 0
foreach ($entry in $plan) {
    Assert-NoReparseChain $entry.src
    Assert-NoReparseChain $entry.dst
    $srcHash = Get-LowerSha256 $entry.src
    $beforeExists = Test-Path -LiteralPath $entry.dst -PathType Leaf
    $beforeHash = if ($beforeExists) { Get-LowerSha256 $entry.dst } else { $null }
    if ($beforeExists -and ($beforeHash -ceq $srcHash)) {
        $deployed += [pscustomobject]@{
            target = $entry.dst
            sourceSha256 = $srcHash
            beforeSha256 = $beforeHash
            afterSha256 = $beforeHash
            written = $false
            backupPath = $null
        }
        continue
    }
    if ($beforeExists) {
        Copy-Item -LiteralPath $entry.dst -Destination $entry.bak -Force
    }
    $tmp = "$($entry.dst).$PID.tmp"
    Copy-Item -LiteralPath $entry.src -Destination $tmp -Force
    Move-Item -LiteralPath $tmp -Destination $entry.dst -Force
    $afterHash = Get-LowerSha256 $entry.dst
    if ($afterHash -cne $srcHash) {
        throw "SHA-256 readback mismatch for $($entry.dst): expected $srcHash, got $afterHash"
    }
    $writtenCount++
    $deployed += [pscustomobject]@{
        target = $entry.dst
        sourceSha256 = $srcHash
        beforeSha256 = $beforeHash
        afterSha256 = $afterHash
        written = $true
        backupPath = $(if ($beforeExists) { $entry.bak } else { $null })
    }
}

$manifestObj = [pscustomobject]@{
    schemaVersion = 1
    mode = 'Apply'
    status = 'deployed'
    deployedAtUtc = [datetime]::UtcNow.ToString('o')
    writtenFiles = $writtenCount
    evidenceDirectory = $runDir
    files = $deployed
}
[IO.File]::WriteAllText((Join-Path $runDir 'manifest.json'), (($manifestObj | ConvertTo-Json -Depth 6) + "`n"), $utf8)
$manifestObj | ConvertTo-Json -Depth 6 -Compress
