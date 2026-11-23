#Requires -Version 7.5
<#
.SYNOPSIS
Collect a compact, read-only local shutdown, reboot, bugcheck, PnP hang and crash-artifact snapshot as single JSON.
.DESCRIPTION
Outputs one bounded UTF-8 JSON object without process command lines, raw CPER hex blobs, or sensitive fields.
Splits Get-WinEvent FilterHashtable Id lists to stay well under the 22-ID Windows Event Log limit, distinguishes
NoMatchingEventsFound from parameter/ACL errors, decodes Kernel-Power 41 PowerButtonTimestamp FILETIME values,
deduplicates pre-boot event storms and WER 1001 buckets, extracts bounded setupapi.dev.log section summaries
without file-copy noise, and reports explicit ok/empty/missing/access-denied states for crash dump directories.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 168)][int]$Hours = 24,
    [ValidateRange(5, 180)][int]$PreBootMinutes = 30,
    [ValidateRange(1, 30)][int]$MaxEventsPerBucket = 8,
    [ValidateRange(1, 12)][int]$MaxSetupApiSections = 4,
    [ValidateRange(50, 5000)][int]$SetupApiTailLines = 1500,
    [switch]$SkipEvents,
    [string]$SetupApiLogPathForTest = '',
    [string]$CrashPathsJsonForTest = '',
    [string]$KernelPower41XmlForTest = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

function Limit-SafeText([AllowNull()][string]$Text, [int]$MaxChars = 220) {
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    $clean = ($Text -replace '\r?\n', ' | ').Trim()
    if ($clean.Length -le $MaxChars) { return $clean }
    return ($clean.Substring(0, $MaxChars) + '...')
}

function Convert-FileTimeToLocalIso([AllowNull()][string]$RawValue) {
    if ([string]::IsNullOrWhiteSpace($RawValue) -or $RawValue.Trim() -eq '0') { return $null }
    $ft = 0L
    if (-not [long]::TryParse($RawValue.Trim(), [ref]$ft) -or $ft -le 0L) { return 'invalid-filetime' }
    try {
        return [DateTime]::FromFileTimeUtc($ft).ToLocalTime().ToString('o')
    } catch {
        return 'invalid-filetime'
    }
}

function Parse-EventDataXml([AllowNull()][string]$XmlString) {
    $map = [ordered]@{}
    if ([string]::IsNullOrWhiteSpace($XmlString)) { return [pscustomobject]$map }
    try {
        $xml = [xml]$XmlString
        $evNode = $xml.PSObject.Properties['Event']?.Value
        $edNode = if ($null -ne $evNode) { $evNode.PSObject.Properties['EventData']?.Value } else { $null }
        $dataNodes = if ($null -ne $edNode) { $edNode.PSObject.Properties['Data']?.Value } else { $null }
        if ($null -ne $dataNodes) {
            foreach ($d in @($dataNodes)) {
                if ($null -eq $d) { continue }
                if ($d -is [string]) {
                    $map['_value'] = $d
                    continue
                }
                $k = $d.PSObject.Properties['Name']?.Value
                $v = $d.PSObject.Properties['#text']?.Value
                if ([string]::IsNullOrEmpty($k)) { $k = '_value' }
                $map[$k] = $v
            }
        }
    } catch {
        $map['_xmlParseError'] = $true
    }
    return [pscustomobject]$map
}

function Convert-KernelPower41Xml([string]$XmlString) {
    $ed = Parse-EventDataXml $XmlString
    $pbtRaw = [string]($ed.PSObject.Properties['PowerButtonTimestamp']?.Value)
    return [pscustomobject]@{
        bugcheckCode = $ed.PSObject.Properties['BugcheckCode']?.Value
        bugcheckParameter1 = $ed.PSObject.Properties['BugcheckParameter1']?.Value
        sleepInProgress = $ed.PSObject.Properties['SleepInProgress']?.Value
        powerButtonTimestamp = $pbtRaw
        powerButtonLocalTime = (Convert-FileTimeToLocalIso $pbtRaw)
        longPowerButtonPressDetected = $ed.PSObject.Properties['LongPowerButtonPressDetected']?.Value
        wheaBootErrorCount = $ed.PSObject.Properties['WHEABootErrorCount']?.Value
        bootAppStatus = $ed.PSObject.Properties['BootAppStatus']?.Value
    }
}

function Read-WinEventSafe([hashtable]$Filter, [int]$MaxEvents = 0) {
    try {
        $records = @(if ($MaxEvents -gt 0) {
            Get-WinEvent -FilterHashtable $Filter -MaxEvents $MaxEvents -ErrorAction Stop
        } else {
            Get-WinEvent -FilterHashtable $Filter -ErrorAction Stop
        })
        return [pscustomobject]@{ status = if ($records.Count -gt 0) { 'ok' } else { 'empty' }; events = $records }
    } catch {
        $fqid = [string]$_.FullyQualifiedErrorId
        $ex = $_.Exception
        if ($fqid -match 'NoMatchingEventsFound') {
            return [pscustomobject]@{ status = 'empty'; events = @() }
        }
        if ($ex -is [System.UnauthorizedAccessException] -or $fqid -match 'UnauthorizedAccess|AccessDenied') {
            return [pscustomobject]@{ status = 'access-denied'; events = @() }
        }
        if ($ex.GetType().FullName -match 'EventLogNotFoundException|EventLogInvalidDataException' -or $fqid -match 'LogNotFound') {
            return [pscustomobject]@{ status = 'unavailable'; events = @() }
        }
        throw
    }
}

function Parse-Wer1001Message([AllowNull()][string]$Message) {
    if ([string]::IsNullOrWhiteSpace($Message)) {
        return [pscustomobject]@{ eventName = 'unknown'; p1 = $null; dumpFile = $null }
    }
    $evName = 'unknown'
    $p1Val = $null
    $dmpName = $null
    if ($Message -match '(?:Event Name|事件名称)\s*:\s*([^\r\n]+)') {
        $evName = $Matches[1].Trim()
    }
    if ($Message -match '\bP1\s*:\s*([^\r\n]*)') {
        $v = $Matches[1].Trim()
        if (-not [string]::IsNullOrEmpty($v)) { $p1Val = $v }
    }
    if ($Message -match '([A-Za-z0-9_.-]+\.(?:dmp|hdmp|kdmp|mdmp))') {
        $dmpName = $Matches[1]
    }
    return [pscustomobject]@{
        eventName = $evName
        p1 = $p1Val
        dumpFile = $dmpName
    }
}

function Get-SetupApiSummary([string]$LogPath, [int]$TailLines = 1500, [int]$MaxSections = 6) {
    if ([string]::IsNullOrWhiteSpace($LogPath) -or -not [IO.File]::Exists($LogPath)) {
        return [pscustomobject]@{ path = $LogPath; status = 'missing'; bootSessions = @(); sections = @() }
    }
    $lines = @()
    try {
        $lines = @(Get-Content -LiteralPath $LogPath -Tail $TailLines -ErrorAction Stop)
    } catch [System.UnauthorizedAccessException] {
        return [pscustomobject]@{ path = $LogPath; status = 'access-denied'; bootSessions = @(); sections = @() }
    }
    $bootSessions = [Collections.Generic.List[string]]::new()
    $sections = [Collections.Generic.List[object]]::new()
    $cur = $null
    foreach ($raw in $lines) {
        $trimmed = ([string]$raw).Trim()
        if ($trimmed.StartsWith('[Boot Session:', [StringComparison]::OrdinalIgnoreCase)) {
            $bootSessions.Add($trimmed)
            continue
        }
        if ($trimmed.StartsWith('>>>  [', [StringComparison]::Ordinal)) {
            if ($null -ne $cur) { $sections.Add([pscustomobject]$cur) }
            $cur = [ordered]@{
                header = $trimmed
                sectionStart = $null
                driverVersions = [Collections.Generic.List[string]]::new()
                diagnostics = [Collections.Generic.List[string]]::new()
                sectionEnd = $null
                exitStatus = $null
            }
            continue
        }
        if ($null -eq $cur) { continue }
        if ($trimmed.StartsWith('>>>  Section start ', [StringComparison]::OrdinalIgnoreCase)) {
            $cur.sectionStart = $trimmed
        } elseif ($trimmed.StartsWith('<<<  Section end ', [StringComparison]::OrdinalIgnoreCase)) {
            $cur.sectionEnd = $trimmed
        } elseif ($trimmed.StartsWith('<<<  [Exit status:', [StringComparison]::OrdinalIgnoreCase)) {
            $cur.exitStatus = $trimmed
            $sections.Add([pscustomobject]$cur)
            $cur = $null
        } elseif ($trimmed.StartsWith('!', [StringComparison]::Ordinal)) {
            if ($cur.diagnostics.Count -lt 12) {
                $cur.diagnostics.Add((Limit-SafeText $trimmed 220))
            }
        } elseif ($trimmed -match '(?:^|\s)Driver Version\s*[:=-]\s*(.+)$') {
            $ver = $Matches[1].Trim()
            if ($cur.driverVersions.Count -lt 4 -and -not $cur.driverVersions.Contains($ver)) {
                $cur.driverVersions.Add($ver)
            }
        }
    }
    if ($null -ne $cur) { $sections.Add([pscustomobject]$cur) }
    $severe = @($sections | Where-Object {
        @($_.diagnostics | Where-Object { $_ -like '!!!*' }).Count -gt 0 -or
        ($null -ne $_.exitStatus -and $_.exitStatus -notlike '*SUCCESS*' -and $_.exitStatus -notlike '*0x00000103*')
    })
    $tailPool = @($sections | Select-Object -Last $MaxSections)
    $combined = [Collections.Generic.List[object]]::new()
    foreach ($s in ($severe + $tailPool)) {
        if (-not $combined.Contains($s)) { $combined.Add($s) }
    }
    $recentSections = @($combined | Select-Object -Last ([Math]::Max($MaxSections, 4)) | ForEach-Object {
        [pscustomobject]@{
            header = $_.header
            sectionStart = $_.sectionStart
            driverVersions = @($_.driverVersions)
            diagnostics = @($_.diagnostics)
            sectionEnd = $_.sectionEnd
            exitStatus = $_.exitStatus
        }
    })
    return [pscustomobject]@{
        path = $LogPath
        status = 'ok'
        bootSessions = @($bootSessions | Select-Object -Last 5)
        sections = $recentSections
    }
}

function Get-CrashPathProbe([string]$TargetPath, [bool]$ExpectDirectory, [bool]$ScanOneSubdirLevel = $false, [int]$MaxItems = 5) {
    if ([string]::IsNullOrWhiteSpace($TargetPath)) {
        return [pscustomobject]@{ path = $TargetPath; status = 'missing'; inaccessibleSubdirs = 0; items = @() }
    }
    try {
        if ($ExpectDirectory) {
            $dirInfo = [IO.DirectoryInfo]::new($TargetPath)
            if (-not $dirInfo.Exists) {
                return [pscustomobject]@{ path = $TargetPath; status = 'missing'; inaccessibleSubdirs = 0; items = @() }
            }
            $topEntries = @($dirInfo.GetFileSystemInfos())
            $collected = [Collections.Generic.List[object]]::new()
            $deniedSubs = 0
            foreach ($entry in $topEntries) {
                if ($entry -is [IO.DirectoryInfo] -and $ScanOneSubdirLevel) {
                    try {
                        foreach ($child in @($entry.GetFiles())) {
                            $collected.Add([pscustomobject]@{
                                name = ($entry.Name + '/' + $child.Name)
                                isDir = $false
                                length = $child.Length
                                lastWriteTime = $child.LastWriteTime.ToString('o')
                            })
                        }
                    } catch [System.UnauthorizedAccessException] {
                        $deniedSubs++
                    }
                } else {
                    $isDir = ($entry -is [IO.DirectoryInfo])
                    $collected.Add([pscustomobject]@{
                        name = $entry.Name
                        isDir = $isDir
                        length = if (-not $isDir) { ([IO.FileInfo]$entry).Length } else { $null }
                        lastWriteTime = $entry.LastWriteTime.ToString('o')
                    })
                }
            }
            $sorted = @($collected | Sort-Object lastWriteTime -Descending | Select-Object -First $MaxItems)
            $st = if ($sorted.Count -gt 0) { 'ok' } elseif ($deniedSubs -gt 0) { 'access-denied' } else { 'empty' }
            return [pscustomobject]@{ path = $TargetPath; status = $st; inaccessibleSubdirs = $deniedSubs; items = $sorted }
        } else {
            $fileInfo = [IO.FileInfo]::new($TargetPath)
            if (-not $fileInfo.Exists) {
                return [pscustomobject]@{ path = $TargetPath; status = 'missing'; items = @() }
            }
            return [pscustomobject]@{
                path = $TargetPath
                status = 'ok'
                items = @([pscustomobject]@{
                    name = $fileInfo.Name
                    isDir = $false
                    length = $fileInfo.Length
                    lastWriteTime = $fileInfo.LastWriteTime.ToString('o')
                })
            }
        }
    } catch [System.UnauthorizedAccessException] {
        return [pscustomobject]@{ path = $TargetPath; status = 'access-denied'; inaccessibleSubdirs = 0; items = @() }
    }
}

$now = Get-Date
$os = Get-CimInstance -ClassName Win32_OperatingSystem
$lastBoot = $os.LastBootUpTime

$setupApiPath = if (-not [string]::IsNullOrWhiteSpace($SetupApiLogPathForTest)) {
    $SetupApiLogPathForTest
} else {
    'C:\Windows\inf\setupapi.dev.log'
}

$crashTargets = [ordered]@{
    minidump = 'C:\Windows\Minidump'
    memoryDmp = 'C:\Windows\MEMORY.DMP'
    liveKernelReports = 'C:\Windows\LiveKernelReports'
    werReportArchive = 'C:\ProgramData\Microsoft\Windows\WER\ReportArchive'
    werReportQueue = 'C:\ProgramData\Microsoft\Windows\WER\ReportQueue'
}
if (-not [string]::IsNullOrWhiteSpace($CrashPathsJsonForTest)) {
    $overrideObj = [IO.File]::ReadAllText($CrashPathsJsonForTest, $utf8) | ConvertFrom-Json -ErrorAction Stop
    foreach ($prop in @('minidump', 'memoryDmp', 'liveKernelReports', 'werReportArchive', 'werReportQueue')) {
        $val = $overrideObj.PSObject.Properties[$prop]?.Value
        if (-not [string]::IsNullOrWhiteSpace([string]$val)) {
            $crashTargets[$prop] = [string]$val
        }
    }
}

$syntheticKp41 = if (-not [string]::IsNullOrWhiteSpace($KernelPower41XmlForTest)) {
    Convert-KernelPower41Xml $KernelPower41XmlForTest
} else {
    $null
}

$bootAndPower = [ordered]@{
    status = 'skipped'
    lastBootUpTime = $lastBoot.ToString('o')
    detectedBootEventTime = $lastBoot.ToString('o')
    powerEvents = @()
    thermalStatus = 'skipped'
    thermalEvents = @()
}
$preBootSummary = [ordered]@{
    status = 'skipped'
    windowStart = $null
    windowEnd = $null
    systemBuckets = @()
    wer1001Buckets = @()
}
$wheaSummary7d = [ordered]@{
    status = 'skipped'
    systemWheaCount = 0
    systemWheaLatest = $null
    kernelWheaErrorsCount = 0
    kernelWheaErrorsLatest = $null
}

if (-not $SkipEvents) {
    $since = $now.AddHours(-$Hours)
    # Keep each FilterHashtable Id list <= 12 (Windows Event Log hard limit is 22)
    $powerIdsA = @(12, 13, 41, 42, 86, 88, 107, 109, 1074, 1076)
    $powerIdsB = @(1001, 1015, 6005, 6006, 6008, 6009, 6013, 46, 161, 162, 219)

    $qA = Read-WinEventSafe @{ LogName = 'System'; Id = $powerIdsA; StartTime = $since }
    $qB = Read-WinEventSafe @{ LogName = 'System'; Id = $powerIdsB; StartTime = $since }
    $qAEvs = @(if ($null -ne $qA.events) { $qA.events })
    $qBEvs = @(if ($null -ne $qB.events) { $qB.events })
    $mergedPower = @($qAEvs + $qBEvs | Sort-Object TimeCreated -Descending)

    $bootEv = $mergedPower | Where-Object { $_.ProviderName -eq 'Microsoft-Windows-Kernel-General' -and $_.Id -eq 12 } | Select-Object -First 1
    $bootAnchor = if ($null -ne $bootEv) { $bootEv.TimeCreated } else { $lastBoot }

    $formattedPower = @(foreach ($e in ($mergedPower | Select-Object -First ([Math]::Min(24, $MaxEventsPerBucket + 4)))) {
        $kp41Details = if ($e.ProviderName -eq 'Microsoft-Windows-Kernel-Power' -and $e.Id -eq 41) {
            Convert-KernelPower41Xml ($e.ToXml())
        } else {
            $null
        }
        $u1074Target = $null
        if ($e.Id -eq 1074) {
            $ed1074 = Parse-EventDataXml ($e.ToXml())
            $u1074Target = [pscustomobject]@{
                initiator = Limit-SafeText ([string]($ed1074.PSObject.Properties['param1']?.Value)) 160
                reason = $ed1074.PSObject.Properties['param3']?.Value
                action = $ed1074.PSObject.Properties['param5']?.Value
            }
        }
        [pscustomobject]@{
            time = $e.TimeCreated.ToString('o')
            provider = $e.ProviderName
            id = $e.Id
            level = $e.LevelDisplayName
            message = Limit-SafeText $e.Message 200
            kernelPower41 = $kp41Details
            user32Shutdown = $u1074Target
        }
    })

    $thermalQ = Read-WinEventSafe @{ LogName = 'Microsoft-Windows-Kernel-Power/Thermal-Operational'; StartTime = $since } 10
    $thermalEvs = @(if ($null -ne $thermalQ.events) { $thermalQ.events })
    $bootAndPower.status = if ($qA.status -eq 'access-denied' -or $qB.status -eq 'access-denied') { 'access-denied' } else { 'ok' }
    $bootAndPower.detectedBootEventTime = $bootAnchor.ToString('o')
    $bootAndPower.powerEvents = $formattedPower
    $bootAndPower.thermalStatus = $thermalQ.status
    $bootAndPower.thermalEvents = @(foreach ($te in $thermalEvs) {
        [pscustomobject]@{ time = $te.TimeCreated.ToString('o'); id = $te.Id; message = Limit-SafeText $te.Message 180 }
    })

    # Pre-boot deduplicated buckets
    $preStart = $bootAnchor.AddMinutes(-$PreBootMinutes)
    $preEnd = $bootAnchor.AddMilliseconds(-100)
    $preSysQ = Read-WinEventSafe @{ LogName = 'System'; StartTime = $preStart; EndTime = $preEnd } 400
    $preAppQ = Read-WinEventSafe @{ LogName = 'Application'; StartTime = $preStart; EndTime = $preEnd } 400
    $preSysEvs = @(if ($null -ne $preSysQ.events) { $preSysQ.events })
    $preAppEvs = @(if ($null -ne $preAppQ.events) { $preAppQ.events })

    $sysGroups = @($preSysEvs | Group-Object { "$($_.ProviderName)|$($_.Id)|$($_.LevelDisplayName)" } | Sort-Object { $_.Group[0].TimeCreated } -Descending | Select-Object -First $MaxEventsPerBucket)
    $sysBuckets = @(foreach ($g in $sysGroups) {
        $grpItems = @($g.Group)
        $newest = $grpItems[0]
        $oldest = $grpItems[$grpItems.Count - 1]
        [pscustomobject]@{
            provider = $newest.ProviderName
            id = $newest.Id
            level = $newest.LevelDisplayName
            count = $g.Count
            firstTime = $oldest.TimeCreated.ToString('o')
            lastTime = $newest.TimeCreated.ToString('o')
            sampleMessage = Limit-SafeText $newest.Message 200
        }
    })

    $werEvents = @($preAppEvs | Where-Object { $_.ProviderName -eq 'Windows Error Reporting' -and $_.Id -eq 1001 })
    $werParsed = @(foreach ($we in $werEvents) {
        $p = Parse-Wer1001Message $we.Message
        [pscustomobject]@{
            time = $we.TimeCreated
            eventName = $p.eventName
            p1 = $p.p1
            dumpFile = $p.dumpFile
        }
    })
    $werGroups = @($werParsed | Group-Object { "$($_.eventName)|$($_.p1)|$($_.dumpFile)" } | Sort-Object { $_.Group[0].time } -Descending | Select-Object -First $MaxEventsPerBucket)
    $werBuckets = @(foreach ($wg in $werGroups) {
        $firstItem = @($wg.Group)[0]
        [pscustomobject]@{
            eventName = $firstItem.eventName
            p1 = $firstItem.p1
            dumpFile = $firstItem.dumpFile
            count = $wg.Count
            latestTime = $firstItem.time.ToString('o')
        }
    })

    $preBootSummary.status = 'ok'
    $preBootSummary.windowStart = $preStart.ToString('o')
    $preBootSummary.windowEnd = $preEnd.ToString('o')
    $preBootSummary.systemBuckets = $sysBuckets
    $preBootSummary.wer1001Buckets = $werBuckets

    # 7-day WHEA counts without emitting CPER RawData hex blobs
    $wheaSince = $now.AddDays(-7)
    $wheaSysQ = Read-WinEventSafe @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $wheaSince } 200
    $wheaKerQ = Read-WinEventSafe @{ LogName = 'Microsoft-Windows-Kernel-WHEA/Errors'; StartTime = $wheaSince } 200
    $wheaSysEvs = @(if ($null -ne $wheaSysQ.events) { $wheaSysQ.events })
    $wheaKerEvs = @(if ($null -ne $wheaKerQ.events) { $wheaKerQ.events })
    $wheaSummary7d.status = 'ok'
    $wheaSummary7d.systemWheaCount = $wheaSysEvs.Count
    $wheaSummary7d.systemWheaLatest = if ($wheaSysEvs.Count -gt 0) { $wheaSysEvs[0].TimeCreated.ToString('o') } else { $null }
    $wheaSummary7d.kernelWheaErrorsCount = $wheaKerEvs.Count
    $wheaSummary7d.kernelWheaErrorsLatest = if ($wheaKerEvs.Count -gt 0) { $wheaKerEvs[0].TimeCreated.ToString('o') } else { $null }
}

$setupApiSummary = Get-SetupApiSummary -LogPath $setupApiPath -TailLines $SetupApiTailLines -MaxSections $MaxSetupApiSections
$crashArtifacts = [ordered]@{
    minidump = Get-CrashPathProbe -TargetPath $crashTargets.minidump -ExpectDirectory $true
    memoryDmp = Get-CrashPathProbe -TargetPath $crashTargets.memoryDmp -ExpectDirectory $false
    liveKernelReports = Get-CrashPathProbe -TargetPath $crashTargets.liveKernelReports -ExpectDirectory $true -ScanOneSubdirLevel $true
    werReportArchive = Get-CrashPathProbe -TargetPath $crashTargets.werReportArchive -ExpectDirectory $true
    werReportQueue = Get-CrashPathProbe -TargetPath $crashTargets.werReportQueue -ExpectDirectory $true
}

$snapshot = [ordered]@{
    schemaVersion = 1
    status = 'complete'
    observedAt = $now.ToString('o')
    hostname = $env:COMPUTERNAME
    bootAndPower = [pscustomobject]$bootAndPower
    preBootSummary = [pscustomobject]$preBootSummary
    wheaSummary7d = [pscustomobject]$wheaSummary7d
    setupApiRecent = $setupApiSummary
    crashArtifacts = [pscustomobject]$crashArtifacts
}
if ($null -ne $syntheticKp41) {
    $snapshot['syntheticKernelPower41'] = $syntheticKp41
}

([pscustomobject]$snapshot) | ConvertTo-Json -Depth 8 -Compress
