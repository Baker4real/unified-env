#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$AssetName,
    [string[]]$GhCommand = @('gh')
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or [string]::IsNullOrWhiteSpace($AssetName) -or $AssetName.IndexOfAny([char[]]@([char]13, [char]10)) -ge 0) {
    throw 'Invalid repository or asset name'
}
$prefix = @($GhCommand | Select-Object -Skip 1)
$assetLiteral = ConvertTo-Json -InputObject $AssetName -Compress
$arguments = @(
    'api', '--hostname', 'github.com', '--method', 'GET', "repos/$Repository/releases/latest",
    '--jq', "{tag_name, assets: [.assets[] | select(.name == $assetLiteral) | {name,size,digest,browser_download_url}]}"
)
$raw = @(& $GhCommand[0] @prefix @arguments 2>&1)
if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw 'GitHub release query failed' }
$release = ($raw -join "`n") | ConvertFrom-Json
$assets = @($release.assets | Where-Object { $_.name -ceq $AssetName })
if ($assets.Count -ne 1) { throw "Expected exactly one matching release asset; found $($assets.Count)" }
$asset = $assets[0]
[ordered]@{
    schemaVersion = 1
    repository = $Repository
    tag = [string]$release.tag_name
    asset = [ordered]@{
        name = [string]$asset.name
        size = [long]$asset.size
        digest = [string]$asset.digest
        browserDownloadUrl = [string]$asset.browser_download_url
    }
} | ConvertTo-Json -Depth 5 -Compress
