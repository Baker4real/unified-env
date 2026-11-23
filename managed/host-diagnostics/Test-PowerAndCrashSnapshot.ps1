#Requires -Version 7.5
[CmdletBinding()]
param([string]$EvidenceRoot = 'D:/agents/run-evidence/power-crash-snapshot-tests')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

$runRoot = Join-Path ([IO.Path]::GetFullPath($EvidenceRoot)) ([guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($runRoot)
$entry = Join-Path $PSScriptRoot 'Get-PowerAndCrashSnapshot.ps1'
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

function Invoke-Snapshot([string[]]$Arguments) {
    $psi = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
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
            throw 'power-crash-snapshot-timeout'
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

Check 'synthetic-fixtures-parse-kp41-setupapi-and-acl-states' {
    $fxRoot = Join-Path $runRoot 'fx'
    $emptyMinidump = Join-Path $fxRoot 'Minidump'
    $missingMemDmp = Join-Path $fxRoot 'MEMORY.DMP'
    $lkrRoot = Join-Path $fxRoot 'LiveKernelReports'
    $lkrSub = Join-Path $lkrRoot 'WATCHDOG'
    $werArch = Join-Path $fxRoot 'ReportArchive'
    $deniedDir = Join-Path $fxRoot 'DeniedQueue'
    foreach ($d in @($emptyMinidump, $lkrSub, $werArch, $deniedDir)) {
        [void][IO.Directory]::CreateDirectory($d)
    }
    [IO.File]::WriteAllBytes((Join-Path $lkrSub 'WATCHDOG-20261122-2135.dmp'), [byte[]]@(1, 2, 3, 4))
    [void][IO.Directory]::CreateDirectory((Join-Path $werArch 'AppHang_drvinst.exe_test'))

    $setupLog = Join-Path $fxRoot 'setupapi.dev.log'
    $setupText = @(
        '[Boot Session: 2026/11/22 21:28:09.500]',
        '>>>  [Device Install (DiInstallDevice) - PCI\VEN_10DE&DEV_2C05]',
        '>>>  Section start 2026/11/22 21:34:18.612',
        '     inf:           Driver Version = 11/07/2026,32.0.16.2124',
        '     flq:                Copying ''D:\temp\nvlddmkm.sys'' to ''C:\WINDOWS\System32\DriverStore\Temp\nvlddmkm.sys''.',
        '     flq:                Copying ''D:\temp\nvoglv64.dll'' to ''C:\WINDOWS\System32\DriverStore\Temp\nvoglv64.dll''.',
        '!!!  dvi:                               Detected driver hang while installing device ''PCI\VEN_10DE&DEV_2C05''.',
        '!!!  ndv:                          Error 480: The operation timed out waiting for this device to complete a PnP query-remove request.',
        '<<<  Section end 2026/11/22 21:37:44.404',
        '<<<  [Exit status: FAILURE(0x000001e0)]',
        '[Boot Session: 2026/11/22 21:39:38.500]'
    ) -join "`r`n"
    [IO.File]::WriteAllText($setupLog, $setupText, $utf8)

    $pathsJson = Join-Path $fxRoot 'crash-paths.json'
    ([ordered]@{
        minidump = $emptyMinidump
        memoryDmp = $missingMemDmp
        liveKernelReports = $lkrRoot
        werReportArchive = $werArch
        werReportQueue = $deniedDir
    } | ConvertTo-Json -Compress) | Out-File -LiteralPath $pathsJson -Encoding utf8

    $kp41Xml = '<Event><EventData><Data Name="BugcheckCode">0</Data><Data Name="BugcheckParameter1">0x0</Data><Data Name="SleepInProgress">0</Data><Data Name="PowerButtonTimestamp">134398283121675963</Data><Data Name="LongPowerButtonPressDetected">false</Data><Data Name="WHEABootErrorCount">0</Data><Data Name="BootAppStatus">0</Data></EventData></Event>'

    $prevNative = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $currentPrincipal = "$env:USERDOMAIN\$env:USERNAME"
        $null = & icacls.exe $deniedDir /deny "${currentPrincipal}:(OI)(CI)(F)" 2>&1

        $res = Invoke-Snapshot -Arguments @(
            '-SkipEvents',
            '-SetupApiLogPathForTest', $setupLog,
            '-CrashPathsJsonForTest', $pathsJson,
            '-KernelPower41XmlForTest', $kp41Xml
        )
        Assert ($res.exitCode -eq 0) ('fixture-exit-' + $res.exitCode + ':' + $res.stderr)
        Assert ([string]::IsNullOrWhiteSpace($res.stderr)) ('fixture-stderr:' + $res.stderr)
        Assert (-not $res.stdout.Contains('flq:')) 'file-copy-noise-leaked'

        $json = $res.stdout | ConvertFrom-Json -ErrorAction Stop
        Assert ($json.status -eq 'complete') 'bad-status'
        Assert ($json.syntheticKernelPower41.bugcheckCode -eq '0') 'kp41-bugcheck-mismatch'
        $expectedLocal = [DateTime]::FromFileTimeUtc(134398283121675963L).ToLocalTime().ToString('o')
        Assert ($json.syntheticKernelPower41.powerButtonLocalTime -eq $expectedLocal) ('kp41-filetime-mismatch:' + $json.syntheticKernelPower41.powerButtonLocalTime)

        $secs = @($json.setupApiRecent.sections)
        Assert ($secs.Count -eq 1) ('setupapi-section-count-' + $secs.Count)
        Assert (@($secs[0].driverVersions)[0] -eq '11/07/2026,32.0.16.2124') 'setupapi-version-mismatch'
        Assert (@($secs[0].diagnostics | Where-Object { $_ -like '*Error 480*' }).Count -eq 1) 'setupapi-error480-missing'
        Assert ($secs[0].exitStatus -like '*FAILURE(0x000001e0)*') 'setupapi-exit-mismatch'

        Assert ($json.crashArtifacts.minidump.status -eq 'empty') ('minidump-status-' + $json.crashArtifacts.minidump.status)
        Assert ($json.crashArtifacts.memoryDmp.status -eq 'missing') ('memdmp-status-' + $json.crashArtifacts.memoryDmp.status)
        Assert ($json.crashArtifacts.liveKernelReports.status -eq 'ok') ('lkr-status-' + $json.crashArtifacts.liveKernelReports.status)
        Assert (@($json.crashArtifacts.liveKernelReports.items)[0].name -eq 'WATCHDOG/WATCHDOG-20261122-2135.dmp') 'lkr-item-mismatch'
        Assert ($json.crashArtifacts.werReportArchive.status -eq 'ok') ('werarch-status-' + $json.crashArtifacts.werReportArchive.status)
        Assert ($json.crashArtifacts.werReportQueue.status -eq 'access-denied') ('denied-dir-not-detected:' + $json.crashArtifacts.werReportQueue.status)
    } finally {
        $currentPrincipal = "$env:USERDOMAIN\$env:USERNAME"
        $null = & icacls.exe $deniedDir /remove:d $currentPrincipal 2>&1
        $PSNativeCommandUseErrorActionPreference = $prevNative
    }
}

# Production default path test without passing ANY *ForTest seam parameter (per CODING_STANDARDS.md)
Check 'live-readonly-default-paths-without-fortest-seams' {
    $res = Invoke-Snapshot -Arguments @('-Hours', '24', '-PreBootMinutes', '30', '-MaxEventsPerBucket', '10')
    Assert ($res.exitCode -eq 0) ('live-exit-' + $res.exitCode + ':' + $res.stderr)
    Assert ([string]::IsNullOrWhiteSpace($res.stderr)) ('live-stderr:' + $res.stderr)
    Assert ([Text.Encoding]::UTF8.GetByteCount($res.stdout) -lt 32768) 'live-output-too-large'
    Assert (-not $res.stdout.Contains('RawData')) 'raw-cper-leaked'
    Assert (-not $res.stdout.Contains('flq:')) 'live-setupapi-copy-noise'

    $json = $res.stdout | ConvertFrom-Json -ErrorAction Stop
    Assert ($json.schemaVersion -eq 1 -and $json.status -eq 'complete') 'live-header-invalid'
    Assert ($null -eq $json.PSObject.Properties['syntheticKernelPower41']) 'synthetic-seam-triggered-in-prod'
    Assert ($json.bootAndPower.status -eq 'ok') ('live-bootpower-status-' + $json.bootAndPower.status)
    Assert ($json.preBootSummary.status -eq 'ok') ('live-preboot-status-' + $json.preBootSummary.status)
    Assert ($json.wheaSummary7d.status -eq 'ok') ('live-whea-status-' + $json.wheaSummary7d.status)
    Assert ($json.setupApiRecent.path -eq 'C:\Windows\inf\setupapi.dev.log') ('live-setupapi-path-' + $json.setupApiRecent.path)
    Assert ($json.setupApiRecent.status -in @('ok', 'access-denied', 'missing')) ('live-setupapi-status-' + $json.setupApiRecent.status)
    foreach ($key in @('minidump', 'memoryDmp', 'liveKernelReports', 'werReportArchive', 'werReportQueue')) {
        $st = $json.crashArtifacts.PSObject.Properties[$key]?.Value?.status
        Assert ($st -in @('ok', 'empty', 'missing', 'access-denied')) ("invalid-crash-status-$key-$st")
    }
}

$results = @($cases)
[pscustomobject]@{
    status = if (@($results | Where-Object { -not $_.passed }).Count -eq 0) { 'passed' } else { 'failed' }
    cases = $results.Count
    results = $results
    evidenceDirectory = $runRoot
} | ConvertTo-Json -Depth 8 -Compress
if (@($results | Where-Object { -not $_.passed }).Count -gt 0) { exit 1 }
