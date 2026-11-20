#Requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('\A[0-9a-fA-F]{64}\z')][string]$ExpectedArchiveSha256,
    [string]$EvidenceRoot = 'D:/agents/run-evidence/antigravity-desktop',
    [switch]$Restart
)

$ErrorActionPreference = 'Stop'
$diagnostics = Split-Path -Parent $PSScriptRoot
. "$diagnostics/lib/ProcessProxyReader.ps1"
$appRoot = 'D:\Apps\Google.Antigravity'
$app = Join-Path $appRoot 'Antigravity.exe'
$backend = Join-Path $appRoot 'resources/bin/language_server.exe'
$archive = Join-Path $appRoot 'resources/app.asar'
$archiveHash = (Get-FileHash -LiteralPath $archive).Hash
if ($archiveHash -ine $ExpectedArchiveSha256) { throw 'Antigravity archive differs from the expected build.' }
$version = (Get-Item -LiteralPath $app).VersionInfo.ProductVersion
$shortcut = Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'Google Antigravity.lnk'
$launcher = 'D:\Apps\Google.Antigravity.Local\LaunchAntigravity.exe'
$mainLog = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Antigravity/logs/main.log'
$wslProbe = Join-Path $diagnostics 'Watch-WslLaunch.ps1'
$wslState = (& (Join-Path $diagnostics 'Get-WslState.ps1')) | ConvertFrom-Json
$wslFeature = @($wslState.windowsFeatures | Where-Object FeatureName -eq 'Microsoft-Windows-Subsystem-Linux')
if ($wslState.status -ne 'complete' -or $wslFeature.Count -ne 1 -or $wslFeature[0].State -ne 'Disabled' -or
    @($wslState.distributions).Count -ne 0 -or @($wslState.wslAppx).Count -ne 0 -or @($wslState.wslProcesses).Count -ne 0 -or
    (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'WSL/wsl.exe') -PathType Leaf) -or
    -not (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32/wsl.exe') -PathType Leaf)) {
    throw 'The WSL installer-stub scenario requires the Windows launcher with WSL disabled and no runtime or distributions.'
}
if (-not [IO.Path]::IsPathFullyQualified($EvidenceRoot)) { throw 'Evidence requires an absolute D drive path.' }
$root = [IO.Path]::GetFullPath($EvidenceRoot)
if ([IO.Path]::GetPathRoot($root) -ine 'D:\' -or $root.Substring(2).Contains(':')) { throw 'Evidence requires an ordinary D drive path.' }
for ($parent = $root; $parent; $parent = [IO.Path]::GetDirectoryName($parent)) {
    if (Test-Path -LiteralPath $parent) {
        $item = Get-Item -LiteralPath $parent -Force
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Evidence path contains a file or reparse point.'
        }
    }
}
$run = Join-Path $root ([guid]::NewGuid().ToString('N'))
$watchDirectory = Join-Path $run 'wsl-launches'

function Get-WindowsHttpsProxy {
    $settings = Get-ItemProperty -LiteralPath 'HKCU:/Software/Microsoft/Windows/CurrentVersion/Internet Settings'
    if ($settings.ProxyEnable -ne 1) { return $null }
    $parts = @(([string]$settings.ProxyServer -split ';').Trim() | Where-Object { $_ })
    $https = $parts | Where-Object { $_ -match '^https\s*=' } | Select-Object -Last 1
    $value = if ($https) { ($https -split '=', 2)[1].Trim() }
        else { $parts | Where-Object { $_ -notlike '*=*' } | Select-Object -Last 1 }
    if (-not $value) { throw 'Windows has no supported manual HTTPS proxy selection.' }
    if ($value -notlike '*://*') { $value = 'http://' + $value }
    $uri = [uri]$value
    if ($uri.Scheme -notin @('http','https') -or -not $uri.IsLoopback -or $uri.UserInfo -or
        $uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.Fragment) { throw 'This host smoke test requires a loopback HTTP(S) proxy.' }
    $uri
}

function Test-GoogleOAuthConnection([uri]$Proxy, [string]$NoProxy) {
    # Do not silently test the proxy when the backend would bypass it for this host.
    if ($Proxy -and $NoProxy -match '(?i)(?:^|,)\s*(?:\*|(?:\*?\.)?googleapis\.com|oauth2\.googleapis\.com)(?::443)?\s*(?:,|$)') {
        throw 'The process NO_PROXY bypasses the Google token endpoint.'
    }
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $handler.UseProxy = $null -ne $Proxy
    if ($Proxy) { $handler.Proxy = [Net.WebProxy]::new($Proxy) }
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [timespan]::FromSeconds(8)
    $client.MaxResponseContentBufferSize = 16KB
    $body = [Net.Http.StringContent]::new('grant_type=authorization_code', [Text.Encoding]::UTF8, 'application/x-www-form-urlencoded')
    try {
        $response = $client.PostAsync('https://oauth2.googleapis.com/token', $body).GetAwaiter().GetResult()
        try {
            $status = [int]$response.StatusCode
            if ($status -ne 400) { throw "Unexpected Google OAuth HTTP status $status." }
            $errorCode = ($response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json).error
            if ($errorCode -ne 'invalid_request') { throw 'Unexpected anonymous OAuth response.' }
            [pscustomobject]@{httpStatus=$status; oauthError='invalid_request'}
        } finally { $response.Dispose() }
    } finally { $body.Dispose(); $client.Dispose() }
}

$proxy = Get-WindowsHttpsProxy
$owner = [guid]::NewGuid().ToString('N')
$ownerHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($owner))).ToLowerInvariant()
$watch = Start-ThreadJob -ArgumentList $wslProbe, $watchDirectory, $owner -ScriptBlock {
    param($probe, $outputDirectory, $proof)
    $env:DSH_WSL_WATCH_OWNER_TOKEN = $proof
    try { & $probe -EvidenceDirectory $outputDirectory -DurationSeconds 18 -PollMilliseconds 125 }
    finally { Remove-Item Env:DSH_WSL_WATCH_OWNER_TOKEN -ErrorAction SilentlyContinue }
}
try {
    $monitorLog = Join-Path $watchDirectory 'events.jsonl'
    $watchDeadline = [datetime]::UtcNow.AddSeconds(7)
    while (-not [IO.File]::Exists($monitorLog) -and $watch.State -notin @('Failed','Completed') -and [datetime]::UtcNow -lt $watchDeadline) {
        Start-Sleep -Milliseconds 120
    }
    if (-not [IO.File]::Exists($monitorLog)) { throw 'WSL launch monitor did not become ready.' }
    $mode = if ($Restart) { 'Restart' } else { 'Open' }
    $window = & (Join-Path $diagnostics 'Open-DesktopShortcut.ps1') -Mode $mode -ShortcutPath $shortcut -ExpectedTarget $launcher -ExecutablePath $app -TimeoutSeconds 12
    if ($window.status -ne 'ready') { throw 'A fresh Antigravity process is required. Use Restart for an authorized open instance.' }
    $appProcess = Get-Process -Id $window.processId
    $created = $appProcess.StartTime.ToUniversalTime()
    if ($appProcess.Path -ine $app -or $created -ne ([datetimeoffset]$window.startedAt).UtcDateTime) {
        throw 'The Antigravity process identity changed after launch.'
    }
    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $($appProcess.Id) AND Name = 'language_server.exe'" |
        Where-Object { $_.SessionId -eq $appProcess.SessionId -and $_.ExecutablePath -ieq $backend -and $_.CreationDate.ToUniversalTime() -ge $created })
    if ($children.Count -ne 1) { throw 'The fresh application did not start its Windows login backend.' }
    $backendProcess = Get-Process -Id $children[0].ProcessId
    Initialize-ProxyReader
    foreach ($process in @($appProcess, $backendProcess)) {
        $values = [HostDiagnostics.ProxyReader]::ReadProxy($process.Id, $process.StartTime.ToFileTimeUtc())
        if ([string]$values['HTTPS_PROXY'] -ine $(if ($proxy) { $proxy.GetLeftPart([UriPartial]::Authority) } else { '' })) {
            throw 'The new desktop processes did not inherit the active Windows HTTPS proxy.'
        }
    }
    $oauth = Test-GoogleOAuthConnection $proxy ([string]$values['NO_PROXY'])
    if ((Get-WindowsHttpsProxy) -ne $proxy) { throw 'Windows proxy selection changed during the check.' }
    if (-not (Wait-Job -Job $watch -Timeout 24)) { throw 'WSL launch monitoring did not finish.' }
    $monitor = Receive-Job -Job $watch -ErrorAction Stop | ConvertFrom-Json
    if ($monitor.status -ne 'complete' -or $monitor.ownerTokenSha256 -cne $ownerHash -or $monitor.eventCount -ne 0 -or
        ([datetime]$monitor.endedAt).ToUniversalTime() -lt $created.AddSeconds(3)) {
        throw 'A WSL launch was seen or the post-launch observation window was incomplete.'
    }
    $log = Get-Item -LiteralPath $mainLog
    if ($log.LastWriteTimeUtc -lt $created) { throw 'Antigravity did not produce a fresh startup log.' }
    $recentWslErrors = @(foreach ($line in Get-Content -LiteralPath $mainLog -Tail 300) {
        if ($line -match '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})\].*(Failed to list WSL distros|wsl\.exe --list --verbose)') {
            if ([datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture).ToUniversalTime() -ge $created.AddMilliseconds(-1)) { 1 }
        }
    })
    if ($recentWslErrors.Count -ne 0) { throw 'The fresh Antigravity log records a WSL probe failure.' }
    $appProcess.Refresh()
    if ((Get-FileHash -LiteralPath $archive).Hash -ine $archiveHash -or $appProcess.HasExited -or
        $appProcess.MainWindowHandle -eq 0 -or -not $appProcess.Responding -or $backendProcess.HasExited) {
        throw 'Antigravity lost its window or backend, or its archive changed during verification.'
    }
    $report = [pscustomobject]@{
        status='passed'; version=$version; archiveSha256=$archiveHash; shortcut=$shortcut
        appPid=$appProcess.Id; backendPid=$backendProcess.Id; launchUtc=$created.ToString('o')
        proxyPort=$(if ($proxy) { $proxy.Port } else { $null }); oauth=$oauth
        wslStartsObserved=0; wslStartupErrors=0; monitorStartedUtc=$monitor.startedAt; monitorEndedUtc=$monitor.endedAt
        processState='running_handed_off'; evidenceDirectory=$run
    }
    $json = $report | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText((Join-Path $run 'result.json'), $json)
    $json
} finally {
    if ($watch.State -notin @('Completed','Failed','Stopped')) { Stop-Job -Job $watch }
    Remove-Job -Job $watch
}
