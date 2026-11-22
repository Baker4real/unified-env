#Requires -Version 7.5
<#
.SYNOPSIS
Collect a compact, read-only local performance, VRAM, storage SMART and recent hardware-event snapshot as single JSON.
.DESCRIPTION
Outputs one bounded UTF-8 JSON object without process command lines or sensitive fields.
Resolves smartctl and nvidia-smi from PATH (falling back to smartmontools default path for smartctl).
Uses smartctl --scan and -d nvme -x /dev/sdX (non-elevated NVMe path on Windows) and preserves non-zero exit codes
such as bitmask 8 (SMART FAILED) instead of aborting.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 30)][int]$TopProcesses = 10,
    [ValidateRange(1, 30)][int]$EventDays = 7,
    [ValidateRange(0, 10)][int]$LiveCpuSeconds = 2,
    [switch]$SkipSmart,
    [switch]$SkipEvents,
    [switch]$SkipGpuCounters
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

function Resolve-ToolPath([string]$Name, [string[]]$Fallbacks = @()) {
    $cmd = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace($cmd.Source)) {
        return $cmd.Source
    }
    foreach ($candidate in $Fallbacks) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return $candidate
        }
    }
    return $null
}

function Invoke-NativeCapture([string]$Executable, [string[]]$Arguments) {
    $prevNative = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $stdoutLines = @(& $Executable @Arguments 2>&1)
        $code = $LASTEXITCODE
        $text = ($stdoutLines | ForEach-Object { [string]$_ }) -join "`n"
        return [pscustomobject]@{ exitCode = $code; output = $text }
    } finally {
        $PSNativeCommandUseErrorActionPreference = $prevNative
    }
}

function Parse-SmartOutput([string]$Device, [int]$ExitCode, [string]$Text) {
    $fields = [ordered]@{
        device = $Device
        exitCode = $ExitCode
        model = $null
        serial = $null
        firmware = $null
        eui64 = $null
        overallHealth = $null
        criticalWarning = $null
        temperature = $null
        availableSpare = $null
        percentageUsed = $null
        dataUnitsWritten = $null
        mediaErrors = $null
        errorLogEntries = $null
        unrecoveredReadEntries = 0
    }
    $prefixMap = [ordered]@{
        'Model Number:' = 'model'
        'Serial Number:' = 'serial'
        'Firmware Version:' = 'firmware'
        'Namespace 1 IEEE EUI-64:' = 'eui64'
        'SMART overall-health self-assessment test result:' = 'overallHealth'
        'Critical Warning:' = 'criticalWarning'
        'Temperature:' = 'temperature'
        'Available Spare:' = 'availableSpare'
        'Percentage Used:' = 'percentageUsed'
        'Data Units Written:' = 'dataUnitsWritten'
        'Media and Data Integrity Errors:' = 'mediaErrors'
        'Error Information Log Entries:' = 'errorLogEntries'
    }
    $unrecovered = 0
    foreach ($rawLine in ($Text -split "`r?`n")) {
        $line = $rawLine.Trim()
        if ($line.Contains('Unrecovered Read Error')) {
            $unrecovered++
        }
        foreach ($kv in $prefixMap.GetEnumerator()) {
            if ($null -eq $fields[$kv.Value] -and $line.StartsWith($kv.Key, [StringComparison]::Ordinal)) {
                $fields[$kv.Value] = $line.Substring($kv.Key.Length).Trim()
                break
            }
        }
    }
    $fields['unrecoveredReadEntries'] = $unrecovered
    return [pscustomobject]$fields
}

$now = Get-Date
$cimProps = @('ProcessId', 'Name', 'SessionId', 'KernelModeTime', 'UserModeTime', 'HandleCount', 'ThreadCount', 'PrivatePageCount')
$liveSw = [Diagnostics.Stopwatch]::StartNew()
$cimSnap1 = @{}
try {
    foreach ($cp in @(Get-CimInstance -ClassName Win32_Process -Property $cimProps -ErrorAction Stop)) {
        $procId = [int]$cp.ProcessId
        $cimSnap1[$procId] = [pscustomobject]@{
            name = [string]$cp.Name
            sessionId = [int]$cp.SessionId
            kernelTime = if ($null -ne $cp.KernelModeTime) { [double]$cp.KernelModeTime } else { $null }
            userTime = if ($null -ne $cp.UserModeTime) { [double]$cp.UserModeTime } else { $null }
            handles = if ($null -ne $cp.HandleCount) { [int]$cp.HandleCount } else { 0 }
            threads = if ($null -ne $cp.ThreadCount) { [int]$cp.ThreadCount } else { 0 }
            privateBytes = if ($null -ne $cp.PrivatePageCount) { [double]$cp.PrivatePageCount } else { 0.0 }
        }
    }
} catch {}

$os = Get-CimInstance -ClassName Win32_OperatingSystem
$uptimeDays = [math]::Round(($now - $os.LastBootUpTime).TotalDays, 2)
$totalPhysGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
$freePhysGB = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
$totalVirtGB = [math]::Round($os.TotalVirtualMemorySize / 1MB, 2)
$freeVirtGB = [math]::Round($os.FreeVirtualMemory / 1MB, 2)

$poolNonpagedGB = $null
$poolPagedGB = $null
try {
    $poolCounters = Get-Counter -Counter @(
        '\Memory\Pool Nonpaged Bytes',
        '\Memory\Pool Paged Bytes'
    ) -ErrorAction Stop
    foreach ($ps in $poolCounters.CounterSamples) {
        if ($ps.Path -like '*pool nonpaged bytes*') { $poolNonpagedGB = [math]::Round([double]$ps.CookedValue / 1GB, 2) }
        elseif ($ps.Path -like '*pool paged bytes*') { $poolPagedGB = [math]::Round([double]$ps.CookedValue / 1GB, 2) }
    }
} catch {}

$memoryInfo = [pscustomobject]@{
    totalPhysicalGB = $totalPhysGB
    freePhysicalGB = $freePhysGB
    freePhysicalPercent = if ($totalPhysGB -gt 0) { [math]::Round(($freePhysGB / $totalPhysGB) * 100, 1) } else { 0.0 }
    totalVirtualGB = $totalVirtGB
    freeVirtualGB = $freeVirtGB
    committedGB = [math]::Round($totalVirtGB - $freeVirtGB, 2)
    poolNonpagedGB = $poolNonpagedGB
    poolPagedGB = $poolPagedGB
}

$allProcs = @(Get-Process -ErrorAction SilentlyContinue)
$procNameById = @{}
foreach ($proc in $allProcs) {
    $procNameById[$proc.Id] = $proc.ProcessName
}

$topByMem = @(
    $allProcs |
        Sort-Object -Property PrivateMemorySize64 -Descending |
        Select-Object -First $TopProcesses |
        ForEach-Object {
            $cpuSec = $null
            if ($cimSnap1.ContainsKey($_.Id)) {
                $ci = $cimSnap1[$_.Id]
                if ($null -ne $ci.kernelTime -and $null -ne $ci.userTime) {
                    $cpuSec = [math]::Round(($ci.kernelTime + $ci.userTime) / 1e7, 1)
                }
            }
            if ($null -eq $cpuSec -and $null -ne $_.CPU) {
                $cpuSec = [math]::Round($_.CPU, 1)
            }
            [pscustomobject]@{
                id = $_.Id
                name = $_.ProcessName
                wsMB = [math]::Round($_.WorkingSet64 / 1MB, 1)
                pmMB = [math]::Round($_.PrivateMemorySize64 / 1MB, 1)
                cpuSeconds = $cpuSec
            }
        }
)

$topByHandles = @(
    $allProcs |
        Sort-Object -Property HandleCount -Descending |
        Select-Object -First $TopProcesses |
        ForEach-Object {
            [pscustomobject]@{
                id = $_.Id
                name = $_.ProcessName
                sessionId = $_.SessionId
                handles = $_.HandleCount
                threads = $_.Threads.Count
                pmMB = [math]::Round($_.PrivateMemorySize64 / 1MB, 1)
            }
        }
)

$gpuResult = [ordered]@{
    status = 'unavailable'
    toolPath = $null
    adapter = $null
    adapterMemory = @()
    topVramProcesses = @()
}
$nvSmiPath = Resolve-ToolPath -Name 'nvidia-smi'
if ($null -ne $nvSmiPath) {
    $gpuResult['toolPath'] = $nvSmiPath
    $nvRun = Invoke-NativeCapture -Executable $nvSmiPath -Arguments @(
        '--query-gpu=name,driver_version,memory.total,memory.used,memory.free,temperature.gpu,utilization.gpu,pstate',
        '--format=csv,noheader,nounits'
    )
    if ($nvRun.exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($nvRun.output)) {
        $firstLine = @($nvRun.output -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) | Select-Object -First 1
        if ($null -ne $firstLine) {
            $cols = @($firstLine -split ',' | ForEach-Object { $_.Trim() })
            if ($cols.Count -ge 8) {
                $gpuResult['status'] = 'ok'
                $gpuResult['adapter'] = [pscustomobject]@{
                    name = $cols[0]
                    driverVersion = $cols[1]
                    memoryTotalMiB = $cols[2]
                    memoryUsedMiB = $cols[3]
                    memoryFreeMiB = $cols[4]
                    tempC = $cols[5]
                    gpuUtilPct = $cols[6]
                    pstate = $cols[7]
                }
            } else {
                $gpuResult['status'] = 'parse-error'
            }
        }
    } else {
        $gpuResult['status'] = 'error'
        $gpuResult['exitCode'] = $nvRun.exitCode
    }
}

if (-not $SkipGpuCounters) {
    try {
        $gpuCounters = Get-Counter -Counter @(
            '\GPU Process Memory(*)\Dedicated Usage',
            '\GPU Process Memory(*)\Local Usage',
            '\GPU Process Memory(*)\Shared Usage',
            '\GPU Process Memory(*)\Total Committed'
        ) -ErrorAction Stop
        $byPid = @{}
        foreach ($sample in $gpuCounters.CounterSamples) {
            if ($sample.InstanceName -match 'pid_(\d+)_') {
                $pidVal = [int]$Matches[1]
                if (-not $byPid.ContainsKey($pidVal)) {
                    $byPid[$pidVal] = [ordered]@{ ded = 0.0; loc = 0.0; shr = 0.0; com = 0.0 }
                }
                if ($sample.Path -like '*dedicated usage*') { $byPid[$pidVal]['ded'] += [double]$sample.CookedValue }
                elseif ($sample.Path -like '*local usage*') { $byPid[$pidVal]['loc'] += [double]$sample.CookedValue }
                elseif ($sample.Path -like '*shared usage*') { $byPid[$pidVal]['shr'] += [double]$sample.CookedValue }
                elseif ($sample.Path -like '*total committed*') { $byPid[$pidVal]['com'] += [double]$sample.CookedValue }
            }
        }
        $vramRows = @(
            foreach ($entry in $byPid.GetEnumerator()) {
                $pidKey = [int]$entry.Key
                $pName = if ($procNameById.ContainsKey($pidKey)) { $procNameById[$pidKey] } else { '?' }
                [pscustomobject]@{
                    pid = $pidKey
                    name = $pName
                    dedMB = [math]::Round($entry.Value['ded'] / 1MB, 1)
                    localMB = [math]::Round($entry.Value['loc'] / 1MB, 1)
                    sharedMB = [math]::Round($entry.Value['shr'] / 1MB, 1)
                    committedMB = [math]::Round($entry.Value['com'] / 1MB, 1)
                }
            }
        )
        $gpuResult['topVramProcesses'] = @($vramRows | Sort-Object -Property localMB, committedMB, dedMB -Descending | Select-Object -First $TopProcesses)
    } catch {
        $gpuResult['vramCounterStatus'] = 'unavailable'
    }

    try {
        $adapterCounters = Get-Counter -Counter @(
            '\GPU Adapter Memory(*)\Dedicated Usage',
            '\GPU Adapter Memory(*)\Shared Usage',
            '\GPU Adapter Memory(*)\Total Committed'
        ) -ErrorAction Stop
        $byLuid = @{}
        foreach ($sample in $adapterCounters.CounterSamples) {
            $luidKey = [string]$sample.InstanceName
            if (-not $byLuid.ContainsKey($luidKey)) {
                $byLuid[$luidKey] = [ordered]@{ ded = 0.0; shr = 0.0; com = 0.0 }
            }
            if ($sample.Path -like '*dedicated usage*') { $byLuid[$luidKey]['ded'] = [double]$sample.CookedValue }
            elseif ($sample.Path -like '*shared usage*') { $byLuid[$luidKey]['shr'] = [double]$sample.CookedValue }
            elseif ($sample.Path -like '*total committed*') { $byLuid[$luidKey]['com'] = [double]$sample.CookedValue }
        }
        $gpuResult['adapterMemory'] = @(
            foreach ($entry in ($byLuid.GetEnumerator() | Sort-Object -Property Key)) {
                [pscustomobject]@{
                    luid = $entry.Key
                    dedicatedGB = [math]::Round($entry.Value['ded'] / 1GB, 3)
                    sharedGB = [math]::Round($entry.Value['shr'] / 1GB, 3)
                    committedGB = [math]::Round($entry.Value['com'] / 1GB, 3)
                }
            }
        )
    } catch {
        $gpuResult['adapterMemoryStatus'] = 'unavailable'
    }
}

$disks = @(
    Get-Disk -ErrorAction SilentlyContinue | Sort-Object -Property Number | ForEach-Object {
        $diskObj = $_
        $letters = @(
            Get-Partition -DiskNumber $diskObj.Number -ErrorAction SilentlyContinue |
                Where-Object { $null -ne $_.DriveLetter -and [char]$_.DriveLetter -ne [char]0 } |
                ForEach-Object { "$($_.DriveLetter):" }
        )
        [pscustomobject]@{
            diskNumber = $diskObj.Number
            model = $diskObj.FriendlyName
            busType = [string]$diskObj.BusType
            healthStatus = [string]$diskObj.HealthStatus
            sizeGB = [math]::Round($diskObj.Size / 1GB, 1)
            serial = $diskObj.SerialNumber
            uniqueId = $diskObj.UniqueId
            letters = $letters
        }
    }
)

$smartResult = [ordered]@{
    status = if ($SkipSmart) { 'skipped' } else { 'unavailable' }
    toolPath = $null
    drives = @()
}
if (-not $SkipSmart) {
    $smartctlPath = Resolve-ToolPath -Name 'smartctl' -Fallbacks @('C:\Program Files\smartmontools\bin\smartctl.exe')
    if ($null -ne $smartctlPath) {
        $smartResult['toolPath'] = $smartctlPath
        $scan = Invoke-NativeCapture -Executable $smartctlPath -Arguments @('--scan')
        if ($scan.exitCode -eq 0) {
            $driveList = [Collections.Generic.List[object]]::new()
            foreach ($scanLine in ($scan.output -split "`r?`n")) {
                if ($scanLine -match '^\s*(/dev/\S+)\s+-d\s+(\S+)') {
                    $devPath = $Matches[1]
                    $devType = $Matches[2]
                    $probe = Invoke-NativeCapture -Executable $smartctlPath -Arguments @('-d', $devType, '-x', $devPath)
                    $driveList.Add((Parse-SmartOutput -Device $devPath -ExitCode $probe.exitCode -Text $probe.output))
                }
            }
            $smartResult['drives'] = @($driveList)
            $smartResult['status'] = if (@($driveList | Where-Object { $_.overallHealth -eq 'FAILED!' -or (($_.exitCode -band 8) -ne 0) }).Count -gt 0) { 'alert' } else { 'ok' }
        } else {
            $smartResult['status'] = 'scan-error'
            $smartResult['scanExitCode'] = $scan.exitCode
        }
    }
}

$eventsResult = [ordered]@{
    status = if ($SkipEvents) { 'skipped' } else { 'ok' }
    windowDays = $EventDays
    system = @()
    classPnp502_505 = [pscustomobject]@{ count = 0; latest = $null }
    radarPreLeak = @()
}
if (-not $SkipEvents) {
    $since = $now.AddDays(-$EventDays)
    $sysEvents = @(
        Get-WinEvent -FilterHashtable @{
            LogName = 'System'
            ProviderName = @('Microsoft-Windows-WHEA-Logger', 'disk', 'stornvme', 'nvlddmkm', 'Display', 'Ntfs', 'Kernel-Power')
            StartTime = $since
            Level = @(1, 2, 3)
        } -ErrorAction SilentlyContinue
    )
    $eventsResult['system'] = @(
        $sysEvents | Group-Object -Property ProviderName, Id | Sort-Object -Property Count -Descending | ForEach-Object {
            $latestEv = $_.Group | Sort-Object -Property TimeCreated -Descending | Select-Object -First 1
            [pscustomobject]@{
                provider = $latestEv.ProviderName
                id = $latestEv.Id
                count = $_.Count
                latest = $latestEv.TimeCreated.ToString('o')
            }
        }
    )
    $cpEvents = @(
        Get-WinEvent -FilterHashtable @{
            LogName = 'Microsoft-Windows-Storage-ClassPnP/Operational'
            StartTime = $since
        } -ErrorAction SilentlyContinue | Where-Object { $_.Id -in @(502, 505) }
    )
    $eventsResult['classPnp502_505'] = [pscustomobject]@{
        count = $cpEvents.Count
        latest = if ($cpEvents.Count -gt 0) { ($cpEvents | Sort-Object -Property TimeCreated -Descending | Select-Object -First 1).TimeCreated.ToString('o') } else { $null }
    }
    $werEvents = @(
        Get-WinEvent -FilterHashtable @{
            LogName = 'Application'
            ProviderName = 'Windows Error Reporting'
            Id = 1001
            StartTime = $since
        } -ErrorAction SilentlyContinue | Where-Object { $_.Message -like '*RADAR_PRE_LEAK*' }
    )
    $eventsResult['radarPreLeak'] = @(
        $werEvents | Select-Object -First 10 | ForEach-Object {
            $procMatch = if ($_.Message -match 'P1:\s*([^\r\n\s]+)') { $Matches[1] } else { 'unknown' }
            [pscustomobject]@{
                time = $_.TimeCreated.ToString('o')
                process = $procMatch
            }
        }
    )
}

$liveCpuWindowSec = 0.0
$topLiveCpu = @()
if ($LiveCpuSeconds -gt 0 -and $cimSnap1.Count -gt 0) {
    $remainMs = [int][math]::Ceiling(($LiveCpuSeconds - $liveSw.Elapsed.TotalSeconds) * 1000)
    if ($remainMs -gt 0) {
        Start-Sleep -Milliseconds $remainMs
    }
    try {
        $cimSnap2 = @(Get-CimInstance -ClassName Win32_Process -Property $cimProps -ErrorAction Stop)
        $elapsedSec = $liveSw.Elapsed.TotalSeconds
        if ($elapsedSec -gt 0.05) {
            $liveCpuWindowSec = [math]::Round($elapsedSec, 2)
            $logicalCpus = [math]::Max(1, [Environment]::ProcessorCount)
            $deltaRows = [Collections.Generic.List[object]]::new()
            foreach ($cp in $cimSnap2) {
                $procId = [int]$cp.ProcessId
                if ($procId -eq 0 -or -not $cimSnap1.ContainsKey($procId)) { continue }
                $prev = $cimSnap1[$procId]
                if ($null -eq $prev.kernelTime -or $null -eq $prev.userTime -or $null -eq $cp.KernelModeTime -or $null -eq $cp.UserModeTime) { continue }
                $dk = ([double]$cp.KernelModeTime - $prev.kernelTime) / 1e7
                $du = ([double]$cp.UserModeTime - $prev.userTime) / 1e7
                $dt = $dk + $du
                if ($dt -gt 0.01) {
                    $deltaRows.Add([pscustomobject]@{
                        id = $procId
                        name = [IO.Path]::GetFileNameWithoutExtension([string]$cp.Name)
                        sessionId = [int]$cp.SessionId
                        singleCorePct = [math]::Round(($dt / $elapsedSec) * 100, 1)
                        totalCpuPct = [math]::Round(($dt / $elapsedSec / $logicalCpus) * 100, 2)
                        kernelSec = [math]::Round($dk, 3)
                        userSec = [math]::Round($du, 3)
                        handles = if ($null -ne $cp.HandleCount) { [int]$cp.HandleCount } else { 0 }
                        pmMB = if ($null -ne $cp.PrivatePageCount) { [math]::Round([double]$cp.PrivatePageCount / 1MB, 1) } else { 0.0 }
                    })
                }
            }
            $topLiveCpu = @($deltaRows | Sort-Object -Property singleCorePct -Descending | Select-Object -First $TopProcesses)
        }
    } catch {}
}

$snapshot = [pscustomobject]@{
    schemaVersion = 1
    status = 'complete'
    observedAt = $now.ToString('o')
    hostname = $env:COMPUTERNAME
    uptimeDays = $uptimeDays
    lastBootUpTime = $os.LastBootUpTime.ToString('o')
    liveCpuWindowSeconds = $liveCpuWindowSec
    memory = $memoryInfo
    gpu = [pscustomobject]$gpuResult
    topLiveCpuProcesses = $topLiveCpu
    topProcessesByMemory = $topByMem
    topProcessesByHandles = $topByHandles
    storage = [pscustomobject]@{
        disks = $disks
        smart = [pscustomobject]$smartResult
    }
    recentEvents = [pscustomobject]$eventsResult
}

$snapshot | ConvertTo-Json -Depth 8 -Compress
