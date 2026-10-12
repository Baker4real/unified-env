#Requires -Version 7.0
<#
.SYNOPSIS
Read-only, bounded NVIDIA download and proxy snapshot. It does not verify package integrity.
.DESCRIPTION
Offline reads an archived status directory without querying host processes or environment.
Native status codes are retained as codes; a single zero-speed sample is not proof of a stall.
#>
[CmdletBinding()]
param(
    [string]$StatusDirectory = (Join-Path $env:ProgramData 'NVIDIA Corporation/NVIDIA App/UpdateFramework/status/grd'),
    [switch]$Offline,
    [switch]$SkipProcessEnvironment
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

function Read-StatusDocument([string]$Leaf) {
    $path = Join-Path $StatusDirectory $Leaf
    try {
        if (-not [IO.File]::Exists($path)) { return @{readStatus='missing';data=$null} }
        $before = Get-Item -LiteralPath $path -ErrorAction Stop
        $length = $before.Length; $stamp = $before.LastWriteTimeUtc
        if ($length -gt 1MB) { return @{readStatus='size-limit';data=$null} }
        $document = [IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        $after = Get-Item -LiteralPath $path -ErrorAction Stop
        if ($after.Length -ne $length -or $after.LastWriteTimeUtc -ne $stamp) {
            return @{readStatus='changed-during-read';data=$null}
        }
        if ($document -isnot [Collections.IDictionary]) { return @{readStatus='invalid-shape';data=$null} }
        return @{readStatus='ok';data=$document;lastWriteTimeUtc=$stamp.ToString('o');length=$length}
    } catch { return @{readStatus='read-or-parse-failed';data=$null} }
}
function Get-Number($Document, [string]$Key) {
    if ($null -eq $Document -or -not $Document.Contains($Key)) { return $null }
    $value = $Document[$Key]
    if ($value -isnot [ValueType] -or $value -is [bool] -or $value -is [datetime]) { return $null }
    try {
        $number = [double]$value
        if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) { return $null }
        return $number
    } catch { return $null }
}
function Get-Version($Value) {
    if ($Value -is [string] -and $Value -match '\A[0-9]{1,5}(\.[0-9]{1,5}){1,3}\z') { return $Value }
    return $null
}
function Test-NvidiaBypass([string]$Value, [string]$TargetHost) {
    foreach ($part in $Value.Split(',')) {
        $item = $part.Trim().ToLowerInvariant()
        if ($item -eq '*') { return $true }
        $item = $item.TrimStart('.')
        if ($item.Length -gt 0 -and ($TargetHost -eq $item -or $TargetHost.EndsWith('.' + $item,[StringComparison]::OrdinalIgnoreCase))) {
            return $true
        }
    }
    return $false
}
function Get-SafeProxySet($Values) {
    $safe = [ordered]@{}
    foreach ($key in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY')) {
        $value = [string]$Values[$key]
        if ([string]::IsNullOrWhiteSpace($value)) { $safe[$key] = @{status='unset'}; continue }
        $uri = $null
        if (-not [Uri]::TryCreate($value,[UriKind]::Absolute,[ref]$uri) -or
            $uri.Scheme -notin @('http','https','socks','socks4','socks4a','socks5','socks5h') -or
            $uri.Host -notmatch '\A[A-Za-z0-9.\-:\[\]]+\z') {
            $safe[$key] = @{status='unparseable'}; continue
        }
        $safe[$key] = @{status='set';scheme=$uri.Scheme;host=$uri.Host;port=$uri.Port;credentialsPresent=($uri.UserInfo.Length -gt 0)}
    }
    $noProxy = [string]$Values['NO_PROXY']
    $safe['NO_PROXY'] = @{
        isSet = (-not [string]::IsNullOrWhiteSpace($noProxy))
        downloadHostCovered = (Test-NvidiaBypass $noProxy 'international-gfe.download.nvidia.com')
        otaHostCovered = (Test-NvidiaBypass $noProxy 'ota.nvidia.com')
    }
    return $safe
}
function Get-ScopeProxy([EnvironmentVariableTarget]$Target) {
    $values = @{}
    foreach ($key in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY')) {
        $values[$key] = [Environment]::GetEnvironmentVariable($key,$Target)
    }
    return (Get-SafeProxySet $values)
}
function Initialize-ProxyReader {
    if ('HostDiagnostics.ProxyReader' -as [type]) { return }
    Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
namespace HostDiagnostics {
    public static class ProxyReader {
        [StructLayout(LayoutKind.Sequential)] private struct BasicInfo {
            public IntPtr Reserved1, Peb, Reserved2a, Reserved2b, Pid, Reserved3;
        }
        [DllImport("kernel32.dll", SetLastError=true)] private static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
        [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll")] private static extern bool IsWow64Process(IntPtr handle, out bool wow64);
        [DllImport("kernel32.dll")] private static extern bool GetProcessTimes(IntPtr handle, out long creation, out long exit, out long kernel, out long user);
        [DllImport("kernel32.dll", SetLastError=true)] private static extern bool ReadProcessMemory(IntPtr handle, IntPtr address, byte[] data, UIntPtr size, out UIntPtr read);
        [DllImport("ntdll.dll")] private static extern int NtQueryInformationProcess(IntPtr handle, int kind, ref BasicInfo info, int size, out int returned);
        private static byte[] Read(IntPtr handle, long address, int size) {
            if (address <= 0) throw new InvalidOperationException("layout-unavailable");
            var data = new byte[size];
            if (!ReadProcessMemory(handle,new IntPtr(address),data,new UIntPtr((uint)size),out var count) || count.ToUInt64() != (ulong)size)
                throw new InvalidOperationException("memory-unavailable");
            return data;
        }
        private static long Pointer(IntPtr handle, long address) { return BitConverter.ToInt64(Read(handle,address,8),0); }
        public static Dictionary<string,string> ReadProxy(int pid, long expectedCreation) {
            if (IntPtr.Size != 8 || RuntimeInformation.OSArchitecture != Architecture.X64)
                throw new InvalidOperationException("unsupported-architecture");
            var handle = OpenProcess(0x410,false,pid);
            if (handle == IntPtr.Zero) throw new InvalidOperationException("process-unavailable");
            try {
                if (!GetProcessTimes(handle,out var creation,out _,out _,out _) || creation != expectedCreation)
                    throw new InvalidOperationException("identity-changed");
                if (!IsWow64Process(handle,out var wow64) || wow64) throw new InvalidOperationException("unsupported-architecture");
                var info = new BasicInfo();
                if (NtQueryInformationProcess(handle,0,ref info,Marshal.SizeOf<BasicInfo>(),out _) != 0 || info.Pid.ToInt64() != pid)
                    throw new InvalidOperationException("layout-unavailable");
                long parameters = Pointer(handle,info.Peb.ToInt64()+0x20);
                long environment = Pointer(handle,parameters+0x80);
                long length = Pointer(handle,parameters+0x3F0);
                if (length < 2 || length > 1024*1024 || length % 2 != 0) throw new InvalidOperationException("layout-unavailable");
                var entries = new UnicodeEncoding(false,false,true).GetString(Read(handle,environment,(int)length)).Split('\0');
                var selected = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
                foreach (var entry in entries) {
                    int split = entry.IndexOf('=');
                    if (split <= 0) continue;
                    string key = entry.Substring(0,split).ToUpperInvariant();
                    if (key == "HTTP_PROXY" || key == "HTTPS_PROXY" || key == "ALL_PROXY" || key == "NO_PROXY")
                        selected[key] = entry.Substring(split+1);
                }
                return selected;
            } finally { CloseHandle(handle); }
        }
    }
}
'@ | Out-Null
}

$downloadDocument = Read-StatusDocument 'download.json'
$postDocument = Read-StatusDocument 'postprocessing.json'
$download = $downloadDocument.data
$total = Get-Number $download 'totalBytes'
$received = Get-Number $download 'downloadedBytes'
$speed = Get-Number $download 'downloadSpeed'
$percent = Get-Number $download 'percentComplete'
$errorCode = Get-Number $download 'errorCode'
$httpCode = Get-Number $download 'httpResponseCode'
$assessment = 'unknown'
if (($null -ne $errorCode -and $errorCode -ne 0) -or ($null -ne $httpCode -and $httpCode -ge 400)) {
    $assessment = 'native-error'
} elseif ($null -ne $total -and $null -ne $received -and ($received -lt 0 -or $total -lt 0 -or $received -gt $total)) {
    $assessment = 'inconsistent-counters'
} elseif ($total -gt 0 -and $received -eq $total -and $percent -eq 100 -and $null -ne $errorCode -and $errorCode -eq 0) {
    $assessment = 'bytes-complete'
} elseif ($total -gt 0 -and $null -ne $received -and $received -lt $total -and $speed -gt 0) {
    $assessment = 'transferring'
} elseif ($total -gt 0 -and $null -ne $received -and $received -lt $total -and $null -ne $speed -and $speed -eq 0) {
    $assessment = 'no-progress-in-snapshot'
}
$sameTask = $null
if ($null -ne $download -and $null -ne $postDocument.data -and
    $download.taskId -is [string] -and $postDocument.data.taskId -is [string] -and $download.taskId.Length -gt 0) {
    $sameTask = [string]::Equals($download.taskId,$postDocument.data.taskId,[StringComparison]::Ordinal)
}
$result = [ordered]@{
    schemaVersion = 1
    observedAtUtc = [DateTime]::UtcNow.ToString('o')
    collectionMode = $(if ($Offline) { 'status-files-only' } else { 'live-read-only' })
    download = [ordered]@{
        sourceStatus = $downloadDocument.readStatus
        lastWriteTimeUtc = $downloadDocument.lastWriteTimeUtc
        nativeStateCode = (Get-Number $download 'state')
        assessment = $assessment
        version = (Get-Version $download.version)
        percentComplete = $percent
        downloadedBytes = $received
        totalBytes = $total
        downloadSpeed = $speed
        errorCode = $errorCode
        httpResponseCode = $httpCode
        integrityVerification = 'not-performed'
    }
    postprocessing = [ordered]@{
        sourceStatus = $postDocument.readStatus
        lastWriteTimeUtc = $postDocument.lastWriteTimeUtc
        nativeStatusCode = (Get-Number $postDocument.data 'status')
        sameTask = $sameTask
    }
    proxy = $null
    processes = @()
    processCollection = $(if ($Offline) { 'not-requested' } else { 'pending' })
    limitations = @('single-snapshot-does-not-prove-stall','byte-count-does-not-prove-integrity','NO_PROXY-does-not-bypass-TUN')
}
if (-not $Offline) {
    $result.proxy = @{process=(Get-ScopeProxy Process);user=(Get-ScopeProxy User);machine=(Get-ScopeProxy Machine)}
    if ($SkipProcessEnvironment) {
        $result.processCollection = 'not-requested'
    } else {
        try {
            Initialize-ProxyReader
            $sessionId = (Get-Process -Id $PID).SessionId
            $targets = @(Get-Process -Name 'nvcontainer' -ErrorAction SilentlyContinue |
                Where-Object SessionId -EQ $sessionId | Sort-Object Id)
            $result.processCount = $targets.Count
            $rows = foreach ($target in @($targets | Select-Object -First 4)) {
                $row = [ordered]@{pid=$target.Id;name='nvcontainer';startedAtUtc=$null;environmentStatus='unavailable';proxy=$null}
                try {
                    $startTime = $target.StartTime.ToUniversalTime()
                    $row.startedAtUtc = $startTime.ToString('o')
                    $values = [HostDiagnostics.ProxyReader]::ReadProxy($target.Id,$startTime.ToFileTimeUtc())
                    $row.proxy = Get-SafeProxySet $values
                    $row.environmentStatus = 'read'
                } catch { $row.environmentStatus = 'unavailable' }
                [pscustomobject]$row
            }
            $result.processes = @($rows)
            $result.processCollection = $(if ($targets.Count -gt 4) { 'limited-to-four' } elseif ($targets.Count -eq 0) { 'no-current-session-nvcontainer' } else { 'observed' })
        } catch { $result.processCollection = 'unavailable' }
    }
}
$json = $result | ConvertTo-Json -Depth 10 -Compress
if ([Text.Encoding]::UTF8.GetByteCount($json + [Environment]::NewLine) -gt 6000) {
    [Console]::Error.WriteLine('nvidia-diagnostic-output-budget-exceeded')
    exit 2
}
$json
