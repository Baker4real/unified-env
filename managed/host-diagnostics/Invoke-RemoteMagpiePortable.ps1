#requires -Version 7.4
<#
.SYNOPSIS
Install or inspect the official Magpie portable Windows executable through RemoteStep.
.DESCRIPTION
Plan and Verify are remote read-only. Every call writes local D-drive transport evidence.
Install never upgrades a different executable, launches, stops, or restarts an application.
ReleaseMetadataPath pins a previously reviewed official api/latest response for repeat verification.
#>
[CmdletBinding()]
param(
    [ValidateSet('Plan','Install','Verify')][string]$Mode = 'Plan',
    [Parameter(Mandatory)][ValidateSet('office','study')][string]$Target,
    [Parameter(Mandatory)][string]$ExpectedComputerName,
    [Parameter(Mandatory)][string]$InteractiveUser,
    [Parameter(Mandatory)][ValidateSet('amd64','arm64')][string]$Architecture,
    [string]$InstallDirectory = 'D:/Apps/Magpie',
    [string]$ReleaseMetadataPath,
    [string]$DownloadProxy,
    [switch]$RequireRunning,
    [string]$EvidenceRoot = 'D:/agents/run-evidence/remote-magpie-portable'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
function Resolve-OrdinaryDPath([string]$Path,[switch]$SyntaxOnly) {
    if ($Path -notmatch '^[Dd]:[\\/]' -or $Path.Substring(2).Contains(':')) { throw 'Expected an absolute ordinary D-drive path' }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full.Length -le 3) { throw 'A drive root is not allowed' }
    if ($SyntaxOnly) { return $full } # A target path belongs to the remote filesystem.
    $current = $full
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse path refused: $current" }
            if ($current -ne $full -and -not $item.PSIsContainer) { throw "Non-directory ancestor: $current" }
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
    $full
}
if ($ExpectedComputerName -notmatch '^[A-Za-z0-9-]{1,63}$' -or $InteractiveUser -notmatch '^[^\\/\r\n]+\\[^\\/\r\n]+$') { throw 'Explicit computer name and DOMAIN\User are required' }
$install = Resolve-OrdinaryDPath $InstallDirectory -SyntaxOnly
$evidence = Resolve-OrdinaryDPath $EvidenceRoot
if ($evidence -eq $install -or $evidence.StartsWith($install+'\',[StringComparison]::OrdinalIgnoreCase) -or $install.StartsWith($evidence+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'EvidenceRoot and InstallDirectory must not overlap' }
if ($DownloadProxy -and $DownloadProxy -notmatch '^(?:http|socks5h)://127\.0\.0\.1:[0-9]{1,5}$') { throw 'DownloadProxy must be a credential-free loopback HTTP or socks5h URL' }
$metadata = if ($ReleaseMetadataPath) {
    $metadataFile = Resolve-OrdinaryDPath $ReleaseMetadataPath
    [IO.File]::ReadAllText($metadataFile, $utf8) | ConvertFrom-Json
} else { Invoke-RestMethod -Uri 'https://usemagpie.ai/api/latest' -TimeoutSec 30 }
$version = [string]$metadata.version
if ($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw 'Invalid official release version' }
$assetName = "magpie-windows-$Architecture.exe"
$property = $metadata.assets.PSObject.Properties[$assetName]
if ($null -eq $property) { throw "Official release lacks asset: $assetName" }
$raw = $property.Value
$sha = [string]$raw.sha256
if ($sha -notmatch '^[a-fA-F0-9]{64}$' -or $raw.size -isnot [long] -and $raw.size -isnot [int] -or [long]$raw.size -le 0) { throw 'Official asset requires a size and SHA256' }
$allowedUrls = @("https://usemagpie.ai/files/v$version/$assetName", "https://github.com/yetone/magpie-releases/releases/download/v$version/$assetName")
if ([string]$raw.url -cnotin $allowedUrls) { throw 'Asset URL is not the expected official version/architecture URL' }
$asset = [ordered]@{version=$version;name=$assetName;url=[string]$raw.url;size=[long]$raw.size;sha256=$sha.ToLowerInvariant()}
$request = [ordered]@{mode=$Mode;target=$Target;computer=$ExpectedComputerName;interactiveUser=$InteractiveUser;architecture=$Architecture;installDirectory=$install;asset=$asset;downloadProxy=$DownloadProxy;requireRunning=$RequireRunning.IsPresent}
$payloadPath = Join-Path $PSScriptRoot 'MagpiePortablePayload.ps1'
$step = Join-Path $PSScriptRoot 'Invoke-RemoteStep.ps1'
foreach ($file in @($payloadPath,$step)) { if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing sibling: $file" } }
$run = Join-Path $evidence ([guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $run
$bundlePath = Join-Path $run 'bundle.json'
[IO.File]::WriteAllText((Join-Path $run 'release-metadata.json'),($metadata | ConvertTo-Json -Depth 20),$utf8)
[IO.File]::WriteAllText($bundlePath,(@{request=$request;script=[IO.File]::ReadAllText($payloadPath,$utf8)} | ConvertTo-Json -Depth 12 -Compress),$utf8)
$bootstrap = Join-Path $run 'remote.ps1'
$source = "if (`$env:CODEX_REMOTE_EXECUTION_TARGET -ne '$Target') { throw 'Remote execution context required: $Target' }`n" + @'
$ErrorActionPreference = 'Stop'
$bundle = [Console]::In.ReadToEnd() | ConvertFrom-Json
& ([scriptblock]::Create($bundle.script)) -Request $bundle.request
'@
[IO.File]::WriteAllText($bootstrap,$source,$utf8)
$stdin = Join-Path $run 'stdin.ps1'
[IO.File]::WriteAllText($stdin,('[IO.File]::ReadAllText(''' + $bundlePath.Replace("'","''") + ''')'),$utf8)
$arguments = @{Target=$Target;ScriptPath=$bootstrap;StdinScript=$stdin;OutputPath=(Join-Path $run 'remote.out.txt');IncludeOutput=$true;TimeoutSeconds=300}
if ($Mode -eq 'Install') { $arguments.WriteOperation = $true }
$global:LASTEXITCODE = 0
$transport = (& $step @arguments) | ConvertFrom-Json
$transportExit = $LASTEXITCODE
if ($transport.outputTruncated -or [string]::IsNullOrWhiteSpace($transport.output)) { throw "Remote result absent or truncated; inspect $run" }
$result = $transport.output | ConvertFrom-Json
$result | Add-Member NoteProperty evidenceDirectory $run
[IO.File]::WriteAllText((Join-Path $run 'result.json'),($result|ConvertTo-Json -Depth 12),$utf8)
[Console]::Out.WriteLine(($result|ConvertTo-Json -Depth 12 -Compress))
if ($transportExit -ne 0 -or $transport.status -ne 'ok' -or $result.status -eq 'failed') { exit 1 }
