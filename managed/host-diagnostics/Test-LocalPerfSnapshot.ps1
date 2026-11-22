#Requires -Version 7.5
[CmdletBinding()]
param([string]$EvidenceRoot = 'D:/agents/run-evidence/local-perf-snapshot-tests')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

$runRoot = Join-Path ([IO.Path]::GetFullPath($EvidenceRoot)) ([guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($runRoot)
$entry = Join-Path $PSScriptRoot 'Get-LocalPerfSnapshot.ps1'
$cases = [Collections.Generic.List[object]]::new()

function Check([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        $cases.Add([pscustomobject]@{ name = $Name; passed = $true })
    } catch {
        $cases.Add([pscustomobject]@{ name = $Name; passed = $false; reason = $_.Exception.Message })
    }
}

function Assert([bool]$Condition, [string]$Reason) {
    if (-not $Condition) { throw $Reason }
}

function Invoke-Snapshot([string[]]$Arguments, [string]$PrependPath = $null) {
    $psi = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    if (-not [string]::IsNullOrWhiteSpace($PrependPath)) {
        $psi.Environment['PATH'] = "$PrependPath;$env:PATH"
    }
    foreach ($arg in @('-NoProfile', '-NonInteractive', '-File', $entry) + $Arguments) {
        $psi.ArgumentList.Add($arg)
    }
    $child = [Diagnostics.Process]::Start($psi)
    try {
        $stdoutTask = $child.StandardOutput.ReadToEndAsync()
        $stderrTask = $child.StandardError.ReadToEndAsync()
        if (-not $child.WaitForExit(30000)) {
            $child.Kill($true)
            [void]$child.WaitForExit(5000)
            throw 'local-perf-snapshot-timeout'
        }
        return [pscustomobject]@{
            exitCode = $child.ExitCode
            stdout = $stdoutTask.GetAwaiter().GetResult()
            stderr = $stderrTask.GetAwaiter().GetResult()
        }
    } finally {
        $child.Dispose()
    }
}

# Build PATH-resolved stub directory (production resolution path, zero *ForTest seam bypass)
$stubDir = Join-Path $runRoot 'stubs'
[void][IO.Directory]::CreateDirectory($stubDir)

$smartStub = @'
@echo off
if "%1"=="--scan" (
  echo /dev/sda -d nvme # /dev/sda, NVMe device
  echo /dev/sdb -d nvme # /dev/sdb, NVMe device
  exit /b 0
)
if "%4"=="/dev/sda" (
  echo Model Number:                       TEST_OK_NVME 1TB
  echo Serial Number:                      SN_OK_001
  echo Firmware Version:                   FW1
  echo Namespace 1 IEEE EUI-64:            001b44 8b47000001
  echo SMART overall-health self-assessment test result: PASSED
  echo Critical Warning:                   0x00
  echo Temperature:                        40 Celsius
  echo Available Spare:                    100%%
  echo Percentage Used:                    1%%
  echo Data Units Written:                 1000 [1.0 TB]
  echo Media and Data Integrity Errors:    0
  echo Error Information Log Entries:      0
  exit /b 0
)
if "%4"=="/dev/sdb" (
  echo Model Number:                       TEST_FAIL_NVME 1TB
  echo Serial Number:                      SN_FAIL_002
  echo Firmware Version:                   FW2
  echo Namespace 1 IEEE EUI-64:            001b44 8b47000002
  echo SMART overall-health self-assessment test result: FAILED!
  echo Critical Warning:                   0x04
  echo Temperature:                        46 Celsius
  echo Available Spare:                    100%%
  echo Percentage Used:                    0%%
  echo Data Units Written:                 11549410 [5.91 TB]
  echo Media and Data Integrity Errors:    12
  echo Error Information Log Entries:      12
  echo   0         12     6  0x0006  0xc502      -   1643540160     1     -  Unrecovered Read Error
  echo   1         11     8  0x00a3  0xc502      -   1643540136     1     -  Unrecovered Read Error
  exit /b 8
)
exit /b 2
'@
[IO.File]::WriteAllText((Join-Path $stubDir 'smartctl.cmd'), $smartStub, [Text.ASCIIEncoding]::new())

$nvStub = @'
@echo off
echo NVIDIA Test GPU, 621.01, 16303, 4092, 11904, 38, 4, P3
exit /b 0
'@
[IO.File]::WriteAllText((Join-Path $stubDir 'nvidia-smi.cmd'), $nvStub, [Text.ASCIIEncoding]::new())

Check 'path-resolved-stubs-parse-smart-failed-rc8-and-gpu' {
    $res = Invoke-Snapshot -Arguments @('-TopProcesses', '5', '-LiveCpuSeconds', '0', '-SkipEvents', '-SkipGpuCounters') -PrependPath $stubDir
    Assert ($res.exitCode -eq 0) ('unexpected-exit-' + $res.exitCode)
    Assert ([string]::IsNullOrWhiteSpace($res.stderr)) ('unexpected-stderr:' + $res.stderr)
    $json = $res.stdout | ConvertFrom-Json -ErrorAction Stop
    Assert ($json.schemaVersion -eq 1 -and $json.status -eq 'complete') 'bad-header'
    Assert ($json.liveCpuWindowSeconds -eq 0 -and @($json.topLiveCpuProcesses).Count -eq 0) 'live-cpu-not-skipped'
    Assert ($json.gpu.status -eq 'ok') ('gpu-status-' + $json.gpu.status)
    Assert ($json.gpu.toolPath.StartsWith($stubDir, [StringComparison]::OrdinalIgnoreCase)) ('gpu-stub-not-resolved:' + $json.gpu.toolPath)
    Assert ($json.gpu.adapter.name -eq 'NVIDIA Test GPU' -and $json.gpu.adapter.memoryFreeMiB -eq '11904') 'gpu-parse-mismatch'
    Assert ($json.storage.smart.status -eq 'alert') ('smart-status-' + $json.storage.smart.status)
    Assert ($json.storage.smart.toolPath.StartsWith($stubDir, [StringComparison]::OrdinalIgnoreCase)) ('smart-stub-not-resolved:' + $json.storage.smart.toolPath)
    $drives = @($json.storage.smart.drives)
    Assert ($drives.Count -eq 2) ('drive-count-' + $drives.Count)
    $failDrive = @($drives | Where-Object { $_.device -eq '/dev/sdb' })[0]
    Assert ($failDrive.exitCode -eq 8 -and $failDrive.overallHealth -eq 'FAILED!' -and $failDrive.criticalWarning -eq '0x04') 'smart-fail-parse-mismatch'
    Assert ($failDrive.mediaErrors -eq '12' -and $failDrive.unrecoveredReadEntries -eq 2) 'smart-media-errors-mismatch'
    Assert (@($json.topProcessesByMemory).Count -le 5) 'top-processes-not-bounded'
    Assert (@($json.topProcessesByHandles).Count -ge 1 -and @($json.topProcessesByHandles).Count -le 5) 'top-handles-not-bounded'
    Assert ($null -ne $json.memory.PSObject.Properties['poolNonpagedGB'] -and $null -ne $json.memory.PSObject.Properties['poolPagedGB']) 'pool-fields-missing'
    Assert (-not $res.stdout.Contains('CommandLine')) 'commandline-leaked'
}

Check 'live-readonly-snapshot-is-bounded-valid-json' {
    $res = Invoke-Snapshot -Arguments @('-TopProcesses', '5', '-EventDays', '3', '-LiveCpuSeconds', '1')
    Assert ($res.exitCode -eq 0) ('live-exit-' + $res.exitCode)
    Assert ([string]::IsNullOrWhiteSpace($res.stderr)) ('live-stderr:' + $res.stderr)
    Assert ([Text.Encoding]::UTF8.GetByteCount($res.stdout) -lt 32768) 'live-output-too-large'
    $json = $res.stdout | ConvertFrom-Json -ErrorAction Stop
    Assert ($json.status -eq 'complete' -and $json.memory.totalPhysicalGB -gt 0) 'live-memory-missing'
    Assert ($json.liveCpuWindowSeconds -ge 0.9) ('live-cpu-window-too-short:' + $json.liveCpuWindowSeconds)
    Assert (@($json.topLiveCpuProcesses).Count -ge 1 -and @($json.topLiveCpuProcesses).Count -le 5) 'live-cpu-processes-missing'
    $firstLive = @($json.topLiveCpuProcesses)[0]
    Assert ($null -ne $firstLive.PSObject.Properties['singleCorePct'] -and $null -ne $firstLive.PSObject.Properties['sessionId']) 'live-cpu-schema-missing'
    Assert (@($json.topProcessesByHandles).Count -ge 1 -and @($json.topProcessesByHandles).Count -le 5) 'live-handles-missing'
    Assert ($null -ne $json.gpu.PSObject.Properties['adapterMemory']) 'gpu-adapter-memory-missing'
    if (@($json.gpu.topVramProcesses).Count -gt 0) {
        Assert ($null -ne @($json.gpu.topVramProcesses)[0].PSObject.Properties['committedMB']) 'gpu-committed-mb-missing'
    }
    Assert (@($json.storage.disks).Count -ge 1) 'live-disks-missing'
    Assert ($json.recentEvents.status -eq 'ok') 'live-events-failed'
}

$results = @($cases)
[pscustomobject]@{
    status = if (@($results | Where-Object { -not $_.passed }).Count -eq 0) { 'passed' } else { 'failed' }
    cases = $results.Count
    results = $results
    evidenceDirectory = $runRoot
} | ConvertTo-Json -Depth 8 -Compress
if (@($results | Where-Object { -not $_.passed }).Count -gt 0) { exit 1 }
