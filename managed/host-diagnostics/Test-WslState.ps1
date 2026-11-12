#Requires -Version 7.5
[CmdletBinding()]
param([string]$EvidenceRoot = 'D:/agents/run-evidence/wsl-state-tests')
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$runRoot = Join-Path ([IO.Path]::GetFullPath($EvidenceRoot)) ([guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($runRoot)
$entry = Join-Path $PSScriptRoot 'Get-WslState.ps1'
$cases = [Collections.Generic.List[object]]::new()

function Check([string]$Name, [scriptblock]$Body) {
    try { & $Body; $cases.Add([pscustomobject]@{name=$Name;passed=$true}) }
    catch { $cases.Add([pscustomobject]@{name=$Name;passed=$false;reason=$_.Exception.Message}) }
}
function Assert([bool]$Condition, [string]$Reason) { if (-not $Condition) { throw $Reason } }
function Invoke-State([string[]]$Arguments) {
    $psi = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8; $psi.StandardErrorEncoding = $utf8
    foreach ($argument in @('-NoProfile','-NonInteractive','-File',$entry) + $Arguments) { $psi.ArgumentList.Add($argument) }
    $child = [Diagnostics.Process]::Start($psi)
    try {
        $stdoutTask = $child.StandardOutput.ReadToEndAsync()
        $stderrTask = $child.StandardError.ReadToEndAsync()
        if (-not $child.WaitForExit(30000)) {
            $child.Kill($true)
            [void]$child.WaitForExit(5000)
            throw 'wsl-state-timeout'
        }
        [pscustomobject]@{
            exitCode = $child.ExitCode
            stdout = $stdoutTask.GetAwaiter().GetResult()
            stderr = $stderrTask.GetAwaiter().GetResult()
        }
    }
    finally { $child.Dispose() }
}
function Get-Report($Result) {
    Assert ([string]::IsNullOrWhiteSpace($Result.stderr)) 'wsl-state-unexpected-stderr'
    Assert ($Result.exitCode -eq 0) ('wsl-state-exit-' + $Result.exitCode)
    $Result.stdout | ConvertFrom-Json -ErrorAction Stop
}

$appxPath = Join-Path $runRoot 'appx.json'
$lxssPath = Join-Path $runRoot 'lxss.json'
[IO.File]::WriteAllText($appxPath, (ConvertTo-Json -Depth 5 -InputObject @(
    [pscustomobject]@{Name='MicrosoftCorporationII.WindowsSubsystemForLinux';Version='3.0.5.0';PackageFullName='MicrosoftCorporationII.WindowsSubsystemForLinux_3.0.5.0_x64__8wekyb3d8bbwe';InstallLocation='C:/Program Files/WindowsApps/wsl';Status=0},
    [pscustomobject]@{Name='Canonical.Ubuntu';Version='1.0';PackageFullName='Canonical.Ubuntu_1.0_x64__test';InstallLocation='C:/Program Files/WindowsApps/ubuntu';Status=0},
    [pscustomobject]@{Name='Microsoft.PowerShell';Version='7.0';PackageFullName='Microsoft.PowerShell_7.0_x64__test';InstallLocation='C:/Program Files/WindowsApps/pwsh';Status=0}
)), $utf8)
[IO.File]::WriteAllText($lxssPath, (ConvertTo-Json -Depth 5 -InputObject @(
    [pscustomobject]@{DistributionName=$null;BasePath=$null;Version=$null;State=$null;Flags=$null},
    [pscustomobject]@{DistributionName='Ubuntu';BasePath='D:/WSL/Ubuntu';Version=2;State=1;Flags=15}
)), $utf8)
$fixtureArguments = @('-AppxPackagesForTest',$appxPath,'-LxssEntriesForTest',$lxssPath)

Check 'metadata-key-is-not-a-distribution-and-wsl-package-is-related' {
    $report = Get-Report (Invoke-State $fixtureArguments)
    $distributions = @($report.distributions)
    Assert ($distributions.Count -eq 1 -and $distributions[0].DistributionName -eq 'Ubuntu') 'distribution-filter-failed'
    Assert (@($report.wslAppx).Count -eq 1) 'wsl-appx-not-projected'
    $related = @($report.relatedAppx)
    Assert ($related.Count -eq 2) ('related-appx-count-' + $related.Count)
    Assert (@($related | Where-Object Name -EQ 'MicrosoftCorporationII.WindowsSubsystemForLinux').Count -eq 1) 'wsl-package-missing-from-related'
    Assert (@($related | Where-Object Name -EQ 'Microsoft.PowerShell').Count -eq 0) 'unrelated-package-included'
}

Check 'feature-fallback-uses-cim-without-elevation' {
    $report = Get-Report (Invoke-State ($fixtureArguments + @('-ForceFeatureFallbackForTest')))
    $features = @($report.windowsFeatures)
    Assert ($features.Count -eq 4) ('feature-count-' + $features.Count)
    Assert (@($features | Where-Object Source -NE 'Win32_OptionalFeature').Count -eq 0) 'feature-fallback-source-missing'
    Assert (@($features | Where-Object { $null -eq $_.InstallState }).Count -eq 0) 'feature-fallback-state-missing'
}

$results = @($cases)
[pscustomobject]@{status=$(if (@($results | Where-Object { -not $_.passed }).Count -eq 0) { 'passed' } else { 'failed' });cases=$results.Count;results=$results;evidenceDirectory=$runRoot} | ConvertTo-Json -Depth 8 -Compress
if (@($results | Where-Object { -not $_.passed }).Count -gt 0) { exit 1 }
