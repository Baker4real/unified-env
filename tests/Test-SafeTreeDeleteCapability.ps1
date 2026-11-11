#requires -Version 7.4
# Get-SafeTreeDeleteCapability 从自身目录解析 invoke-safe-tree-delete.ps1 和 Invoke-ManagedRecycle.ps1：
# 每个用例把入口复制进独立夹具目录，旁边放对应版本的受管删除替身。
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$repo = Split-Path -Parent $PSScriptRoot
$source = Join-Path $repo 'managed/host-diagnostics/Get-SafeTreeDeleteCapability.ps1'
$evidence = 'D:/agents/run-evidence/safe-delete-capability-tests/' + [guid]::NewGuid().ToString('N')
$null = New-Item -ItemType Directory -Path $evidence -Force

function New-Fixture([string]$Name, [string]$DeleteScript, [switch]$WithRecycle) {
    $directory = Join-Path $evidence $Name
    $null = New-Item -ItemType Directory -Path $directory -Force
    Copy-Item -LiteralPath $source -Destination (Join-Path $directory 'Get-SafeTreeDeleteCapability.ps1')
    [IO.File]::WriteAllText((Join-Path $directory 'invoke-safe-tree-delete.ps1'), $DeleteScript, $utf8)
    if ($WithRecycle) { [IO.File]::WriteAllText((Join-Path $directory 'Invoke-ManagedRecycle.ps1'), '# fixture', $utf8) }
    $directory
}
function Invoke-Capability([string]$Entry, [string]$Target) {
    $psi = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $Entry, '-TargetPath', $Target)) { $psi.ArgumentList.Add($argument) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    $process = [Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(30000)) { $process.Kill($true); throw 'Capability test timed out' }
    return [pscustomobject]@{ exitCode = $process.ExitCode; report = ($stdout.GetAwaiter().GetResult() | ConvertFrom-Json); stderr = $stderr.GetAwaiter().GetResult() }
}

# 新版：判定原样取自 Check。替身放行 D:\Codex\tmp 下的目标，但拒绝 denied 子树里的后代（旧实现只比精确路径）。
$checkScript = @'
param([ValidateSet('Check','Plan','Apply','Purge','BatchPurge','Status')][string]$Mode, [string]$TargetPath)
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'check-target.txt'), "$Mode|$TargetPath")
$root = 'D:\Codex\tmp'
$allowed = $TargetPath.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase) -and $TargetPath -notmatch '\\denied(\\|$)'
$result = [ordered]@{ targetPath = $TargetPath; allowed = $allowed; policyEntryId = $(if ($allowed) { 'temp' } else { $null }); capabilityRoot = $(if ($allowed) { $root } else { $null }); depth = $null; refusalReason = $(if ($allowed) { $null } else { 'denied-path' }); refusalMessage = $(if ($allowed) { $null } else { 'fixture refusal' }) }
[ordered]@{ allowed = $allowed; targetCount = 1; results = @($result) } | ConvertTo-Json -Depth 5 -Compress
'@
$current = New-Fixture 'current' $checkScript -WithRecycle
$currentEntry = Join-Path $current 'Get-SafeTreeDeleteCapability.ps1'
$cases = 0
$allowed = Invoke-Capability $currentEntry 'D:/Codex/tmp/retired'
if ($allowed.exitCode -ne 0 -or $allowed.report.status -ne 'ok' -or $allowed.report.decisionSource -ne 'safe-delete-check' -or $allowed.report.capabilityRoot -ne 'D:\Codex\tmp' -or -not $allowed.report.managedRecycleAvailable) { throw "Check approval was not reported: $($allowed.stderr)" }
if ([IO.File]::ReadAllText((Join-Path $current 'check-target.txt')) -ne 'Check|D:\Codex\tmp\retired') { throw 'Check did not receive the normalized target' }
if ($allowed.report.supportedModes -notcontains 'Check' -or $allowed.report.capabilityRootRequiredByPlan -or $allowed.report.resultFormat -ne 'json') { throw 'Current delete capability was not identified' }
$cases++
if ($allowed.report.batchGroupingKey -ne 'policyEntryId' -or $allowed.report.hashText -ne 'lowercase-hex-sha256' -or @($allowed.report.modeContracts.BatchPurge.requiredParameters) -notcontains 'TargetPaths') { throw 'Callable mode contracts and grouping/hash recipe are missing.' }
$deniedDescendant = Invoke-Capability $currentEntry 'D:/Codex/tmp/denied/child'
if ($deniedDescendant.exitCode -eq 0 -or $deniedDescendant.report.status -ne 'refused' -or $deniedDescendant.report.allowedByPolicy -ne $false -or $deniedDescendant.report.refusalReason -ne 'denied-path') { throw 'A Check refusal was not passed through' }
$cases++

# 旧版：没有 Check，不报放行结论。
$oldScript = @'
param([ValidateSet('Plan','Apply','Purge','BatchPurge')][string]$Mode)
if ($Mode -eq 'Plan') { throw 'Plan 模式要求 TargetPath 与 CapabilityRoot。' }
'@
$old = Invoke-Capability (Join-Path (New-Fixture 'old' $oldScript) 'Get-SafeTreeDeleteCapability.ps1') 'D:/Codex/tmp/retired'
if ($old.exitCode -eq 0 -or $old.report.status -ne 'check-unavailable' -or $null -ne $old.report.allowedByPolicy -or $old.report.managedRecycleAvailable) { throw 'An old delete script was treated as a policy decision' }
if ($old.report.supportedModes -notcontains 'Plan' -or $old.report.supportedModes -contains 'Check' -or -not $old.report.capabilityRootRequiredByPlan -or $old.report.resultFormat -ne 'powershell-object') { throw 'Old mode set was misread' }
$cases++

# shim 委托到旧实现：Mode 从被委托的实现读，候选 root 来自它所在仓库的 policy。
$fixtureRepo = Join-Path $evidence 'shim-repo'
$null = New-Item -ItemType Directory -Path (Join-Path $fixtureRepo 'scripts'), (Join-Path $fixtureRepo 'managed/safe-tree-delete') -Force
$delegate = Join-Path $fixtureRepo 'scripts/Invoke-CodexSafeTreeDelete.ps1'
[IO.File]::WriteAllText($delegate, $oldScript, $utf8)
@{ schemaVersion = 4; entries = @(@{ id = 'temp'; capabilityRoot = 'D:/Codex/tmp'; minimumDescendantDepth = 1; rootDeletionPurpose = 'none'; deniedExactPaths = @() }) } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $fixtureRepo 'managed/safe-tree-delete/policy.json') -Encoding utf8
$delegated = Invoke-Capability (Join-Path (New-Fixture 'shim' "& '$delegate' @args") 'Get-SafeTreeDeleteCapability.ps1') 'D:/Codex/tmp/retired'
if ($delegated.report.supportedModes -notcontains 'Plan' -or -not $delegated.report.capabilityRootRequiredByPlan -or @($delegated.report.capabilityRootCandidates) -notcontains 'D:\Codex\tmp') { throw 'Shim did not resolve the delegated capability contract' }
$cases++

# The real entry delegates mode validation to its adjacent library, unlike the legacy fixture.
$realDelegate=Join-Path $repo 'scripts/Invoke-CodexSafeTreeDelete.ps1'
$real=Invoke-Capability (Join-Path (New-Fixture 'real-dispatch' "& '$realDelegate' @args") 'Get-SafeTreeDeleteCapability.ps1') 'D:/Codex/tmp/retired'
if(-not $real.report.capabilityRootRequiredByPlan -or @($real.report.modeContracts.Plan.requiredParameters) -notcontains 'CapabilityRoot'){throw 'Real dispatcher Plan contract must include CapabilityRoot.'}
$cases++

# 仓库源码目录里没有受管删除：报缺失，不落到别处的线上入口。
$missing = Invoke-Capability $source 'D:/Codex/tmp/retired'
if ($missing.exitCode -eq 0 -or $missing.report.status -ne 'safe-delete-missing') { throw 'A missing sibling safe-delete was not reported' }
$cases++
[ordered]@{ status = 'passed'; evidence = $evidence; cases = $cases } | ConvertTo-Json -Compress
