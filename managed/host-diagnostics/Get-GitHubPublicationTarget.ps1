#requires -Version 7.4
<#
.SYNOPSIS
只读核验 GitHub 发布目标，按真实可见性返回精简 JSON。
.DESCRIPTION
退出码 0 表示读取成功；仅 ready=true 表示给定预期全部匹配，不代表用户授权。
未传 ExpectedVisibility 时状态为 observed；预期错配退出 2，读取或响应异常退出 1。
GhCommand 沿用可执行文件加前置参数的测试 seam，生产默认为 gh。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$ExpectedOwner,
    [string]$ExpectedBranch = 'main',
    [string]$ExpectedVisibility = '',
    [string[]]$GhCommand = @('gh')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$result = [ordered]@{
    schemaVersion = 1
    repository = $Repository
    owner = $null
    visibility = $null
    defaultBranch = $null
    writePermission = $null
    expected = @{ owner = $ExpectedOwner; branch = $ExpectedBranch; visibility = $(if ($ExpectedVisibility) { $ExpectedVisibility } else { $null }) }
    status = 'error'
    ready = $false
    reasons = @()
    errorCode = $null
    checkedAt = [DateTimeOffset]::UtcNow.ToString('o')
}

function Complete-TargetCheck([int]$ExitCode) {
    [Console]::Out.WriteLine(($result | ConvertTo-Json -Depth 5 -Compress))
    exit $ExitCode
}

# gh 失败只回报固定词表里的类别，不复述原文：原文可能带代理地址或凭据。gh 用退出码 4 表示需要登录。
function Get-GhFailureReason([string]$Text, [int]$ExitCode) {
    if ($Text -match '\(HTTP (\d{3})\)') { return 'http_' + $Matches[1] }
    if ($ExitCode -eq 4 -or $Text -match 'gh auth login') { return 'auth_required' }
    if ($Text -match '\bEOF\b') { return 'network_eof' }
    if ($Text -match '(?i)timeout|timed out|deadline exceeded') { return 'network_timeout' }
    if ($Text -match '(?i)error connecting to|connectex|connection (refused|reset)|forcibly closed|no such host|dial tcp|proxyconnect') { return 'network_connection' }
    return 'unclassified'
}

if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or
    $ExpectedOwner -notmatch '^[A-Za-z0-9_.-]+$' -or [string]::IsNullOrWhiteSpace($ExpectedBranch) -or
    ($ExpectedVisibility -and $ExpectedVisibility -cnotin @('public', 'private', 'internal')) -or
    $GhCommand.Count -eq 0 -or [string]::IsNullOrWhiteSpace($GhCommand[0])) {
    # 无效参数可能是误传的带认证 URL，错误回执不复述它们。
    $result.repository = $null
    $result.expected = @{ owner = $null; branch = $null; visibility = $null }
    $result.errorCode = 'invalid_arguments'
    Complete-TargetCheck 1
}

try {
    $prefix = @($GhCommand | Select-Object -Skip 1)
    # 固定 GET、固定官方主机与字段白名单；绝不返回 gh 的原始失败载荷。
    $arguments = @('api', '--hostname', 'github.com', '--method', 'GET', ('repos/' + $Repository), '--jq', '{full_name,owner:{login:.owner.login},visibility,private,default_branch,permissions:{push:.permissions.push}}')
    $raw = @(& $GhCommand[0] @prefix @arguments 2>&1)
    $ghExitCode = $LASTEXITCODE
    if ($ghExitCode -ne 0) {
        $result.errorCode = 'github_api_failed'
        $result.reasons = @((Get-GhFailureReason ($raw -join "`n") $ghExitCode), "gh_exit_$ghExitCode")
        Complete-TargetCheck 1
    }
    $metadata = ($raw -join "`n") | ConvertFrom-Json -AsHashtable
} catch {
    $result.errorCode = 'github_query_or_json_failed'
    Complete-TargetCheck 1
}

if ($metadata -isnot [Collections.IDictionary] -or
    $metadata['full_name'] -isnot [string] -or $metadata['full_name'] -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or
    $metadata['owner'] -isnot [Collections.IDictionary] -or $metadata['owner']['login'] -isnot [string] -or
    $metadata['owner']['login'] -notmatch '^[A-Za-z0-9_.-]+$' -or
    $metadata['visibility'] -cnotin @('public', 'private', 'internal') -or
    $metadata['private'] -isnot [bool] -or $metadata['default_branch'] -isnot [string] -or
    [string]::IsNullOrWhiteSpace($metadata['default_branch']) -or
    $metadata['permissions'] -isnot [Collections.IDictionary] -or $metadata['permissions']['push'] -isnot [bool] -or
    (($metadata['visibility'] -ceq 'public') -eq $metadata['private'])) {
    $result.errorCode = 'invalid_repository_metadata'
    Complete-TargetCheck 1
}

$result.repository = $metadata.full_name
$result.owner = $metadata.owner.login
$result.visibility = $metadata.visibility
$result.defaultBranch = $metadata.default_branch
$result.writePermission = $metadata.permissions.push
$reasons = [Collections.Generic.List[string]]::new()
if ($metadata.full_name -ine $Repository) { $reasons.Add('repository_mismatch') }
if ($metadata.owner.login -ine $ExpectedOwner -or $metadata.owner.login -ine $Repository.Split('/')[0]) { $reasons.Add('owner_mismatch') }
if ($metadata.default_branch -cne $ExpectedBranch) { $reasons.Add('branch_mismatch') }
if (-not $metadata.permissions.push) { $reasons.Add('write_permission_missing') }
if ($ExpectedVisibility -and $metadata.visibility -cne $ExpectedVisibility) { $reasons.Add('visibility_mismatch') }
$result.reasons = @($reasons)
if ($reasons.Count -gt 0) {
    $result.status = 'mismatch'
    Complete-TargetCheck 2
}
if (-not $ExpectedVisibility) {
    $result.status = 'observed'
    Complete-TargetCheck 0
}
$result.status = 'ready'
$result.ready = $true
Complete-TargetCheck 0
