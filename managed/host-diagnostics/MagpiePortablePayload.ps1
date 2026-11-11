#requires -Version 7.4
# Internal stdin payload. The public controller supplies a literal target assertion in its bootstrap.
param([Parameter(Mandatory)][pscustomobject]$Request)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$changes = [Collections.Generic.List[string]]::new()
$report = [ordered]@{status='failed';mode=$Request.mode;computer=$env:COMPUTERNAME;asset=$Request.asset;changes=@();before=$null;after=$null;downloadPath=$null}
function Assert-OrdinaryPath([string]$Path,[string]$Kind) {
    if (-not [IO.Path]::IsPathFullyQualified($Path) -or $Path -notmatch '^[A-Za-z]:[\\/]' -or $Path.Substring(2).Contains(':')) { throw 'Non-ordinary absolute path refused' }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $current = $full
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse path refused: $current" }
            $directoryRequired = $current -ne $full -or $Kind -eq 'Directory'
            if ($directoryRequired -and -not $item.PSIsContainer) { throw "Directory path conflict: $current" }
            if ($current -eq $full -and $Kind -eq 'File' -and $item.PSIsContainer) { throw "File path conflict: $current" }
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
    $full
}
function Get-InstallationState {
    $null = Assert-OrdinaryPath $root 'Directory'
    $null = Assert-OrdinaryPath $exe 'File'
    $null = Assert-OrdinaryPath $data 'Directory'
    $null = Assert-OrdinaryPath $shortcut 'File'
    $installed = Test-Path -LiteralPath $exe -PathType Leaf
    $actualHash = $null
    if ($installed) {
        $actualHash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $Request.asset.sha256 -or (Get-Item -LiteralPath $exe).Length -ne $Request.asset.size) { throw 'Existing executable differs from official asset; explicit upgrade review required' }
    }
    if (Test-Path -LiteralPath $root) {
        $children = @(Get-ChildItem -LiteralPath $root -Force)
        $unknown = @($children | Where-Object { $_.Name -notin @('magpie.exe','data') })
        if ($unknown.Count -gt 0 -or (-not $installed -and $children.Count -gt 0)) { throw 'Unknown contents in installation directory; inspect before installing' }
    }
    $linkExists = Test-Path -LiteralPath $shortcut -PathType Leaf
    if ($linkExists) {
        $link = $shell.CreateShortcut($shortcut)
        if (-not $link.TargetPath -or [IO.Path]::GetFullPath($link.TargetPath) -ine $exe -or $link.Arguments) { throw 'Existing shortcut target or arguments conflict' }
    }
    [pscustomobject]@{executableExists=$installed;sha256=$actualHash;dataExists=(Test-Path -LiteralPath $data -PathType Container);shortcutExists=$linkExists}
}
function Get-PortableStartupEvidence([object]$Process,[object]$Live) {
    $logPath = Assert-OrdinaryPath (Join-Path $data 'logs/app.log') 'File'
    if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) { throw 'Portable startup log is missing for exited parent' }
    $startedUtc = $Live.StartTime.ToUniversalTime()
    $writtenUtc = (Get-Item -LiteralPath $exe).LastWriteTimeUtc
    if ($writtenUtc -gt $startedUtc -or $startedUtc -gt [DateTime]::UtcNow) { throw 'Executable/process startup times conflict' }
    # Keep only complete startup records, never return other app-log content.
    $pattern = '^(?<time>\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}) magpie (?<version>\d+\.\d+\.\d+) started \(app, pid (?<pid>[1-9]\d*), windows/(?<arch>amd64|arm64)\); this log: (?<path>[^\r\n]+)$'
    $matching = @(Select-String -LiteralPath $logPath -Pattern $pattern | ForEach-Object {
        $fields = $_.Matches[0].Groups
        if ($fields['pid'].Value -eq [string]$Process.ProcessId -and $fields['version'].Value -ceq $Request.asset.version -and $fields['arch'].Value -ceq $Request.architecture -and $fields['path'].Value.Replace('/','\') -ieq $logPath) {
            $localTime = [DateTime]::ParseExact($fields['time'].Value,'yyyy/MM/dd HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None)
            if ([TimeZoneInfo]::Local.IsAmbiguousTime($localTime) -or [TimeZoneInfo]::Local.IsInvalidTime($localTime)) { throw 'Portable startup time is ambiguous in the local time zone' }
            $logUtc = [TimeZoneInfo]::ConvertTimeToUtc($localTime,[TimeZoneInfo]::Local)
            $delta = ($logUtc-$startedUtc).TotalSeconds
            # Log timestamps have second precision; allow one truncated second and ten seconds of startup.
            if ($delta -ge -1 -and $delta -le 10) { $logUtc }
        }
    })
    if ($matching.Count -ne 1) { throw 'Portable startup log does not uniquely match current pid/version/path/start time' }
    [pscustomobject]@{logPath=$logPath;startupUtc=$matching[0].ToString('o');processStartedUtc=$startedUtc.ToString('o');executableWrittenUtc=$writtenUtc.ToString('o')}
}
try {
    if ($Request.target -notin @('office','study') -or $env:CODEX_REMOTE_EXECUTION_TARGET -ne $Request.target) { throw 'Remote execution context required' }
    if ($env:COMPUTERNAME -ine $Request.computer) { throw 'Unexpected computer' }
    if ($Request.mode -notin @('Plan','Install','Verify')) { throw 'Invalid mode' }
    $architecture = switch ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()) { 'X64' {'amd64'} 'Arm64' {'arm64'} default { throw 'Unsupported Windows architecture' } }
    if (-not $IsWindows -or $architecture -ne $Request.architecture) { throw 'Unexpected OS architecture' }
    if ($Request.installDirectory -notmatch '^[Dd]:[\\/]' -or [IO.Path]::GetFullPath($Request.installDirectory).TrimEnd('\').Length -le 3) { throw 'InstallDirectory must be below D drive' }
    $root = Assert-OrdinaryPath $Request.installDirectory 'Directory'
    $exe = Join-Path $root 'magpie.exe'
    $data = Join-Path $root 'data'
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.UserName -ine $Request.interactiveUser) { throw 'Expected interactive user is not logged on' }
    $explorers = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Where-Object { $_.SessionId -gt 0 } | ForEach-Object {
        $owner = Invoke-CimMethod -InputObject $_ -MethodName GetOwner
        if ($owner.ReturnValue -eq 0 -and ($owner.Domain+'\'+$owner.User) -ieq $Request.interactiveUser) { $_ }
    })
    if ($explorers.Count -ne 1) { throw 'Expected exactly one Explorer for the interactive user' }
    $explorer = $explorers[0]
    $ownerSid = Invoke-CimMethod -InputObject $explorer -MethodName GetOwnerSid
    if ($ownerSid.ReturnValue -ne 0 -or $ownerSid.Sid -notmatch '^S-1-5-[0-9-]+$') { throw 'Cannot resolve interactive user SID' }
    $profiles = @(Get-CimInstance Win32_UserProfile -Filter "SID='$($ownerSid.Sid)'")
    if ($profiles.Count -ne 1 -or -not $profiles[0].LocalPath) { throw 'Cannot resolve interactive user profile' }
    $key = Get-Item -LiteralPath ("Registry::HKEY_USERS\$($ownerSid.Sid)\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders")
    $desktopValue = [string]$key.GetValue('Desktop',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $desktopValue = $desktopValue.Replace('%USERPROFILE%', $profiles[0].LocalPath, [StringComparison]::OrdinalIgnoreCase)
    if (-not $desktopValue -or $desktopValue.Contains('%')) { throw 'Desktop contains unresolved user environment variables' }
    $desktop = Assert-OrdinaryPath $desktopValue 'Directory'
    if (-not (Test-Path -LiteralPath $desktop -PathType Container)) { throw 'Interactive desktop is unavailable' }
    $shortcut = Join-Path $desktop 'Magpie.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $report.installDirectory=$root
    $report.shortcut=$shortcut
    $report.interactiveUser=$Request.interactiveUser
    $report.sessionId=[int]$explorer.SessionId
    $before = Get-InstallationState
    $report.before = $before
    $report.processState = 'not-running'
    $report.processes = @()
    $processes = @(Get-CimInstance Win32_Process -Filter "Name='magpie.exe'")
    if ($processes.Count -gt 0) {
        if (-not $before.executableExists) { throw 'Running process has no verified installed executable' }
        $processEvidence = @(foreach ($proc in $processes) {
            if (-not $proc.ExecutablePath -or [IO.Path]::GetFullPath($proc.ExecutablePath) -ine $exe -or $proc.SessionId -ne $explorer.SessionId) { throw 'Existing Magpie process path/session conflict' }
            $processOwner = Invoke-CimMethod -InputObject $proc -MethodName GetOwnerSid
            if ($processOwner.ReturnValue -ne 0 -or $processOwner.Sid -ne $ownerSid.Sid) { throw 'Existing Magpie process owner SID conflicts with interactive user' }
            $live = Get-Process -Id $proc.ProcessId
            if ($live.HasExited -or -not $live.Responding) { throw 'Existing Magpie process is not responding' }
            $parents = @(Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.ParentProcessId)")
            $startupEvidence = $null
            if ($parents.Count -eq 0) {
                $startupEvidence = Get-PortableStartupEvidence $proc $live
                $parentName = 'exited'
                $launchEvidence = 'portable-startup-log'
            } elseif ($parents.Count -eq 1) {
                $parent = $parents[0]
                $parentOwner = Invoke-CimMethod -InputObject $parent -MethodName GetOwnerSid
                if ($parentOwner.ReturnValue -ne 0 -or $parentOwner.Sid -ne $ownerSid.Sid -or $parent.SessionId -ne $explorer.SessionId -or $parent.ProcessId -eq $proc.ProcessId) { throw 'Existing Magpie live parent owner/session conflict' }
                if ($parent.ProcessId -eq $explorer.ProcessId -and $parent.Name -ieq 'explorer.exe') { $launchEvidence='interactive-explorer' }
                elseif ($parent.Name -ieq 'magpie.exe' -and $parent.ExecutablePath -and [IO.Path]::GetFullPath($parent.ExecutablePath) -ieq $exe) {
                    $parentLive = Get-Process -Id $parent.ProcessId
                    if ($parentLive.HasExited -or -not $parentLive.Responding -or $parentLive.StartTime.ToUniversalTime() -gt $live.StartTime.ToUniversalTime()) { throw 'Existing Magpie live parent health/start time conflict' }
                    $launchEvidence='same-user-magpie-parent'
                } else { throw 'Existing Magpie live parent path/name conflict' }
                $parentName = $parent.Name
            } else { throw 'Ambiguous existing Magpie parent' }
            $listeners = @(Get-NetTCPConnection -State Listen -LocalPort 3425 | Where-Object { $_.OwningProcess -eq $proc.ProcessId -and $_.LocalAddress -in @('127.0.0.1','::1','0.0.0.0','::') })
            if ($listeners.Count -eq 0) { throw 'Existing Magpie gateway listener is not owned by the verified process' }
            [pscustomobject]@{pid=[int]$proc.ProcessId;path=$proc.ExecutablePath;session=[int]$proc.SessionId;ownerSid=$processOwner.Sid;parentPid=[int]$proc.ParentProcessId;parent=$parentName;launchEvidence=$launchEvidence;startupEvidence=$startupEvidence;responding=$true;gatewayPort=3425;health='responding-and-owned-listener'}
        })
        $report.processes = $processEvidence
        $report.processState = 'running-verified'
    } elseif ($Request.requireRunning) { throw 'Magpie is not running; this entry never launches it' }
    if ($Request.mode -eq 'Plan') {
        $report.status = 'planned'
    } elseif ($Request.mode -eq 'Verify') {
        if (-not ($before.executableExists -and $before.dataExists -and $before.shortcutExists)) { throw 'Installation incomplete' }
        $report.status = 'verified'
    } else {
        if (-not $before.executableExists) {
            if (-not (Test-Path -LiteralPath $root)) { $null=New-Item -ItemType Directory -Path $root; $changes.Add($root) }
            $partial = Join-Path $root ('.magpie-'+[guid]::NewGuid().ToString('N')+'.download')
            $report.downloadPath=$partial
            $stream=[IO.File]::Open($partial,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            $stream.Dispose()
            $changes.Add($partial)
            $curlArgs=@('--fail','--location','--silent','--show-error','--proto','=https','--proto-redir','=https','--connect-timeout','15','--max-time','240','--output',$partial)
            if ($Request.downloadProxy) { $curlArgs += @('--proxy',[string]$Request.downloadProxy) }
            & curl.exe @curlArgs $Request.asset.url
            if ($LASTEXITCODE -ne 0) { throw "Download failed: curl exit $LASTEXITCODE" }
            $null=Assert-OrdinaryPath $partial 'File'
            if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Request.asset.sha256 -or (Get-Item -LiteralPath $partial).Length -ne $Request.asset.size) { throw 'Downloaded asset failed official size/SHA256 verification' }
            $null=Assert-OrdinaryPath $exe 'File'
            $null=Assert-OrdinaryPath $shortcut 'File'
            if (-not $before.shortcutExists -and (Test-Path -LiteralPath $shortcut)) { throw 'Shortcut appeared during download; inspect before installing' }
            [IO.File]::Move($partial,$exe,$false)
            $changes.Add($exe)
        }
        $null=Assert-OrdinaryPath $data 'Directory'
        if (-not $before.dataExists) { $null=New-Item -ItemType Directory -Path $data; $changes.Add($data) }
        if (-not $before.shortcutExists) {
            $null=Assert-OrdinaryPath $shortcut 'File'
            if (Test-Path -LiteralPath $shortcut) { throw 'Shortcut appeared before publication' }
            $stagedLink = Join-Path $desktop ('.Magpie-'+[guid]::NewGuid().ToString('N')+'.lnk')
            $link=$shell.CreateShortcut($stagedLink)
            $link.TargetPath=$exe
            $link.WorkingDirectory=$root
            $link.IconLocation=$exe+',0'
            $link.Description='Magpie AI model manager'
            $link.Save()
            $changes.Add($stagedLink)
            $null=Assert-OrdinaryPath $shortcut 'File'
            [IO.File]::Move($stagedLink,$shortcut,$false)
            $changes.Add($shortcut)
        }
        $report.status=if($changes.Count -gt 0){'installed'}else{'unchanged'}
    }
    $report.after=Get-InstallationState
} catch {
    $report.status='failed'
    $report.error=$_.Exception.Message
} finally {
    $report.changes=@($changes)
}
[Console]::Out.WriteLine(($report|ConvertTo-Json -Depth 10 -Compress))
if ($report.status -eq 'failed') { exit 1 }
