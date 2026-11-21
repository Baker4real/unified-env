#requires -Version 7.0
# Read exact Codex Store and AppX deployment observations.
[CmdletBinding()]
param([Parameter(Mandatory)][ValidatePattern('^\d{1,5}(\.\d{1,5}){3}$')][string]$CurrentVersion)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$product = '9PLM9XGG6VKS'
$current = "OpenAI.Codex_${CurrentVersion}_x64__2p2nqsd0c76g0"
$packagePattern = '\bOpenAI[.]Codex_(\d{1,5}(?:[.]\d{1,5}){3})_x64__2p2nqsd0c76g0\b'
$start = [datetime]::Now.AddDays(-7)

function Read-Events($Filter, [int]$Limit) {
    try { Get-WinEvent -FilterHashtable $Filter -MaxEvents $Limit -ErrorAction Stop }
    catch {
        if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound,*') { throw }
    }
}

function Read-Fields($Event) {
    $fields = @{}
    foreach ($field in ([xml]$Event.ToXml()).Event.EventData.Data) {
        $fields[[string]$field.Name] = [string]$field.InnerText
    }
    return $fields
}

try {
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
using System.Text;
public static class CodexStagedPackage {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    public static extern int GetStagedPackagePathByFullName(string name, ref uint length, StringBuilder path);
    [DllImport("kernelbase.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    public static extern int GetStagedPackageOrigin(string name, out int origin);
}
'@
    $storeRoot = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'WindowsApps'
    $store = @{LogName='Microsoft-Windows-Store/Operational'; Id=2006; StartTime=$start}
    $deployment = 'Microsoft-Windows-AppXDeploymentServer/Operational'
    $offers = @{}
    foreach ($event in @(Read-Events $store 256)) {
        $fields = Read-Fields $event
        if ($fields.ProductId -cne $product -and $fields.Message -notmatch ('\b' + $product + '\b')) { continue }
        foreach ($match in [regex]::Matches($fields.Message, $packagePattern)) {
            $version = [version]$match.Groups[1].Value
            if ($version -le [version]$CurrentVersion -or $offers.ContainsKey($match.Value)) { continue }
            if ($offers.Count -ge 8) { throw 'ambiguous-store-offers' }
            $offers[$match.Value] = [ordered]@{version=$version.ToString(); full_name=$match.Value; store_record=$event.RecordId; stage_record=$null; occupied_record=$null}
        }
    }
    foreach ($offer in $offers.Values) {
        $name = $offer.full_name
        $stages = @{LogName=$deployment; Id=400; StartTime=$start; PackageFullName=$name; DeploymentOperation='4'}
        $stage = Read-Events $stages 1
        if ($null -eq $stage) { continue }
        [uint32]$length = 32768
        $stagedPath = [Text.StringBuilder]::new([int]$length)
        [int]$origin = -1
        if ([CodexStagedPackage]::GetStagedPackagePathByFullName($name, [ref]$length, $stagedPath) -ne 0 -or
            $stagedPath.ToString() -ine (Join-Path $storeRoot $name) -or
            [CodexStagedPackage]::GetStagedPackageOrigin($name, [ref]$origin) -ne 0 -or $origin -ne 3) { continue }
        $offer.stage_record = $stage.RecordId
        $failures = @{LogName=$deployment; Id=404; StartTime=$stage.TimeCreated; PackageFullName=$name}
        foreach ($failure in @(Read-Events $failures 8)) {
            $fields = Read-Fields $failure
            if ($fields.ErrorCode -ieq '0x80073d02' -and $fields.SummaryError.Contains($current,[StringComparison]::Ordinal)) {
                $offer.occupied_record = $failure.RecordId
                break
            }
        }
    }
    [ordered]@{ok=$true; offers=@($offers.Values)} | ConvertTo-Json -Depth 5 -Compress
} catch {
    [ordered]@{ok=$false; offers=@(); error_code='deployment-events-unavailable'} | ConvertTo-Json -Compress
    exit 1
}
