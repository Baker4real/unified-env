#requires -Version 7.4
[CmdletBinding()]
param([string]$EvidenceRoot = 'D:/agents/run-evidence/github-publication-target-tests')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$fixture = Join-Path ([IO.Path]::GetFullPath($EvidenceRoot)) ('case-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($fixture)
$entry = Join-Path $PSScriptRoot 'Get-GitHubPublicationTarget.ps1'
$pwsh = Join-Path $PSHOME 'pwsh.exe'
$fakeGh = Join-Path $fixture 'fake-gh.ps1'
$runner = Join-Path $fixture 'run.ps1'
$cases = [Collections.Generic.List[object]]::new()

[IO.File]::WriteAllText($fakeGh, @'
$ErrorActionPreference = 'Stop'
$state = [IO.File]::ReadAllText($env:GITHUB_TARGET_TEST_STATE) | ConvertFrom-Json -AsHashtable
$expected = @('api', '--hostname', 'github.com', '--method', 'GET', 'repos/Baker4real/kimi-switch-private', '--jq')
if ($args.Count -ne 8) { [Console]::Error.WriteLine('Unexpected argument count'); exit 8 }
for ($i = 0; $i -lt $expected.Count; $i++) {
    if ($args[$i] -cne $expected[$i]) { [Console]::Error.WriteLine('Unexpected request'); exit 8 }
}
[IO.File]::WriteAllText($state.callsPath, ($args | ConvertTo-Json -Compress))
if ($state.mode -eq 'api-error') {
    [Console]::Out.WriteLine('fixture-sensitive-payload')
    [Console]::Error.WriteLine($state.ghStderr)
    exit $state.ghExitCode
}
if ($state.mode -eq 'invalid-json') { [Console]::Out.WriteLine('fixture-sensitive-payload'); exit 0 }
[Console]::Out.WriteLine(($state.response | ConvertTo-Json -Compress -Depth 6))
exit 0
'@, $utf8)

[IO.File]::WriteAllText($runner, @'
$ErrorActionPreference = 'Stop'
$state = [IO.File]::ReadAllText($env:GITHUB_TARGET_TEST_STATE) | ConvertFrom-Json -AsHashtable
$parameters = @{ Repository = 'Baker4real/kimi-switch-private'; ExpectedOwner = 'Baker4real' }
if (-not $state.ContainsKey('pathRoot')) { $parameters.GhCommand = @($state.pwsh, '-NoProfile', '-NonInteractive', '-File', $state.fakeGh) }
if ($state.ContainsKey('visibility')) { $parameters.ExpectedVisibility = $state.visibility }
foreach ($key in $state.parameterOverrides.Keys) { $parameters[$key] = $state.parameterOverrides[$key] }
& $state.entry @parameters
exit $LASTEXITCODE
'@, $utf8)

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Invoke-Case([string]$Name, [hashtable]$Overrides = @{}) {
    $statePath = Join-Path $fixture ($Name + '.json')
    $callsPath = Join-Path $fixture ($Name + '.calls.json')
    $state = @{
        entry = $entry; pwsh = $pwsh; fakeGh = $fakeGh; callsPath = $callsPath
        mode = 'ok'; visibility = 'public'; parameterOverrides = @{}
        ghStderr = 'fixture-sensitive-payload'; ghExitCode = 1
        response = @{ full_name = 'Baker4real/kimi-switch-private'; owner = @{ login = 'Baker4real' }; visibility = 'public'; private = $false; default_branch = 'main'; permissions = @{ push = $true } }
    }
    foreach ($key in $Overrides.Keys) { $state[$key] = $Overrides[$key] }
    if ($Overrides.ContainsKey('visibility') -and $null -eq $Overrides.visibility) { $state.Remove('visibility') }
    [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 8), $utf8)
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $pwsh
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    $psi.Environment['GITHUB_TARGET_TEST_STATE'] = $statePath
    if ($state.ContainsKey('pathRoot')) { $psi.Environment['PATH'] = $state.pathRoot + [IO.Path]::PathSeparator + $env:PATH }
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $runner)) { $psi.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($psi)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(15000)) { throw '预检测试超时。' }
        $out = $stdout.GetAwaiter().GetResult()
        $err = $stderr.GetAwaiter().GetResult()
        Assert-True (-not ($out + $err).Contains('fixture-sensitive-payload')) '预检泄露了原始 API 载荷。'
        Assert-True ([string]::IsNullOrWhiteSpace($err)) '预检应只返回结构化 JSON。'
        $result = $out | ConvertFrom-Json -AsHashtable
        return @{ result = $result; exitCode = $process.ExitCode; callsPath = $callsPath }
    } finally {
        if (-not $process.HasExited) { $process.Kill($true); $null = $process.WaitForExit(5000) }
        $process.Dispose()
    }
}

function Assert-Case([string]$Name, [scriptblock]$Check) {
    try { & $Check; $cases.Add(@{ name = $Name; status = 'passed' }) }
    catch { $cases.Add(@{ name = $Name; status = 'failed'; message = $_.Exception.Message }) }
}

Assert-Case 'public-name-private' {
    $run = Invoke-Case 'public-name-private'
    Assert-True ($run.exitCode -eq 0 -and $run.result.status -eq 'ready' -and $run.result.ready) '公开仓库不应从名字被误判为私有。'
    Assert-True ($run.result.visibility -eq 'public' -and $run.result.repository -eq 'Baker4real/kimi-switch-private') '返回的仓库和可见性不正确。'
    Assert-True (Test-Path -LiteralPath $run.callsPath) '应通过固定 GET 请求获得元数据。'
}

Assert-Case 'missing-permission-is-error' {
    $run = Invoke-Case 'missing-permission-is-error' @{ response = @{ full_name = 'Baker4real/kimi-switch-private'; owner = @{ login = 'Baker4real' }; visibility = 'public'; private = $false; default_branch = 'main' } }
    Assert-True ($run.exitCode -eq 1 -and $run.result.status -eq 'error' -and -not $run.result.ready) '缺少权限信息应关闭发布判定。'
    Assert-True ($run.result.errorCode -eq 'invalid_repository_metadata') '应返回稳定的元数据错误代码。'
}

Assert-Case 'private-matches-confirmed-visibility' {
    $run = Invoke-Case 'private-matches-confirmed-visibility' @{ visibility = 'private'; response = @{ full_name = 'Baker4real/kimi-switch-private'; owner = @{ login = 'Baker4real' }; visibility = 'private'; private = $true; default_branch = 'main'; permissions = @{ push = $true } } }
    Assert-True ($run.exitCode -eq 0 -and $run.result.ready -and $run.result.visibility -eq 'private') '已确认的私有目标应匹配。'
}

Assert-Case 'unconfirmed-visibility-is-observed' {
    $run = Invoke-Case 'unconfirmed-visibility-is-observed' @{ visibility = $null }
    Assert-True ($run.exitCode -eq 0 -and $run.result.status -eq 'observed' -and -not $run.result.ready) '未给可见性预期时只能报告观察结果。'
    Assert-True ($null -eq $run.result.expected.visibility) '不得从名称补出可见性预期。'
}

Assert-Case 'visibility-mismatch' {
    $run = Invoke-Case 'visibility-mismatch' @{ visibility = 'private' }
    Assert-True ($run.exitCode -eq 2 -and $run.result.status -eq 'mismatch' -and -not $run.result.ready) '公开与私有不符时必须非成功退出。'
    Assert-True ($run.result.reasons -contains 'visibility_mismatch' -and $run.result.visibility -eq 'public') '应保留真实可见性并标出错配原因。'
}

Assert-Case 'owner-mismatch' {
    $run = Invoke-Case 'owner-mismatch' @{ response = @{ full_name = 'DifferentOwner/kimi-switch-private'; owner = @{ login = 'DifferentOwner' }; visibility = 'public'; private = $false; default_branch = 'main'; permissions = @{ push = $true } } }
    Assert-True ($run.exitCode -eq 2 -and -not $run.result.ready -and $run.result.reasons -contains 'owner_mismatch' -and $run.result.reasons -contains 'repository_mismatch') '转移后的仓库应明确报告身份不匹配。'
}

Assert-Case 'branch-mismatch' {
    $run = Invoke-Case 'branch-mismatch' @{ response = @{ full_name = 'Baker4real/kimi-switch-private'; owner = @{ login = 'Baker4real' }; visibility = 'public'; private = $false; default_branch = 'release'; permissions = @{ push = $true } } }
    Assert-True ($run.exitCode -eq 2 -and -not $run.result.ready -and $run.result.reasons -contains 'branch_mismatch') '默认分支变化必须非成功退出。'
}

Assert-Case 'write-permission-missing' {
    $run = Invoke-Case 'write-permission-missing' @{ response = @{ full_name = 'Baker4real/kimi-switch-private'; owner = @{ login = 'Baker4real' }; visibility = 'public'; private = $false; default_branch = 'main'; permissions = @{ push = $false } } }
    Assert-True ($run.exitCode -eq 2 -and -not $run.result.ready -and $run.result.reasons -contains 'write_permission_missing') '只有读取权限时不得报告 ready。'
}

Assert-Case 'api-failure-is-redacted' {
    $run = Invoke-Case 'api-failure-is-redacted' @{ mode = 'api-error' }
    Assert-True ($run.exitCode -eq 1 -and $run.result.status -eq 'error' -and -not $run.result.ready -and $run.result.errorCode -eq 'github_api_failed') 'API 失败必须返回稳定错误且不泄露原始载荷。'
    Assert-True ((@($run.result.reasons) -join ',') -eq 'unclassified,gh_exit_1') '无法归类的 gh 失败只回报 unclassified 和退出码。'
}

Assert-Case 'api-failure-reason-classes' {
    foreach ($sample in @(
        @{ stderr = 'gh: fixture-sensitive-payload (HTTP 404)'; exitCode = 1; reason = 'http_404' }
        @{ stderr = 'Get "https://fixture-sensitive-payload@api.example.invalid/repos/x": EOF'; exitCode = 1; reason = 'network_eof' }
        @{ stderr = 'fixture-sensitive-payload: i/o timeout'; exitCode = 1; reason = 'network_timeout' }
        @{ stderr = 'proxyconnect tcp: dial tcp fixture-sensitive-payload: connectex: refused'; exitCode = 1; reason = 'network_connection' }
        @{ stderr = 'To get started with GitHub CLI, please run:  gh auth login'; exitCode = 4; reason = 'auth_required' }
    )) {
        $run = Invoke-Case ('api-failure-' + $sample.reason) @{ mode = 'api-error'; ghStderr = $sample.stderr; ghExitCode = $sample.exitCode }
        Assert-True ($run.exitCode -eq 1 -and $run.result.errorCode -eq 'github_api_failed') "$($sample.reason): gh 失败必须返回 github_api_failed。"
        Assert-True ((@($run.result.reasons) -join ',') -eq "$($sample.reason),gh_exit_$($sample.exitCode)") "$($sample.reason): reasons 应为类别加 gh 退出码。"
    }
}

Assert-Case 'invalid-json-is-redacted' {
    $run = Invoke-Case 'invalid-json-is-redacted' @{ mode = 'invalid-json' }
    Assert-True ($run.exitCode -eq 1 -and $run.result.status -eq 'error' -and $run.result.errorCode -eq 'github_query_or_json_failed') 'JSON 解析失败必须关闭判定。'
}

Assert-Case 'inconsistent-visibility-is-error' {
    $run = Invoke-Case 'inconsistent-visibility-is-error' @{ response = @{ full_name = 'Baker4real/kimi-switch-private'; owner = @{ login = 'Baker4real' }; visibility = 'public'; private = $true; default_branch = 'main'; permissions = @{ push = $true } } }
    Assert-True ($run.exitCode -eq 1 -and $run.result.errorCode -eq 'invalid_repository_metadata') '可见性字段矛盾时应报错。'
}

Assert-Case 'string-permission-is-error' {
    $run = Invoke-Case 'string-permission-is-error' @{ response = @{ full_name = 'Baker4real/kimi-switch-private'; owner = @{ login = 'Baker4real' }; visibility = 'public'; private = $false; default_branch = 'main'; permissions = @{ push = 'false' } } }
    Assert-True ($run.exitCode -eq 1 -and -not $run.result.ready -and $run.result.errorCode -eq 'invalid_repository_metadata') '字符串权限不得按 PowerShell 真值转成允许写入。'
}

Assert-Case 'extra-fields-not-exposed' {
    $run = Invoke-Case 'extra-fields-not-exposed' @{ response = @{ full_name = 'Baker4real/kimi-switch-private'; owner = @{ login = 'Baker4real' }; visibility = 'public'; private = $false; default_branch = 'main'; permissions = @{ push = $true }; token = 'fixture-sensitive-payload' } }
    Assert-True ($run.exitCode -eq 0 -and $run.result.ready -and -not $run.result.ContainsKey('token')) '只允许回报发布目标字段白名单。'
}

Assert-Case 'array-response-is-error' {
    $run = Invoke-Case 'array-response-is-error' @{ response = @('unexpected') }
    Assert-True ($run.exitCode -eq 1 -and $run.result.errorCode -eq 'invalid_repository_metadata') '仓库元数据必须是对象。'
}

Assert-Case 'invalid-input-not-echoed' {
    $run = Invoke-Case 'invalid-input-not-echoed' @{ parameterOverrides = @{ Repository = 'https://fixture-sensitive-payload@example.invalid/Baker4real/repo' } }
    Assert-True ($run.exitCode -eq 1 -and $run.result.errorCode -eq 'invalid_arguments' -and -not (Test-Path -LiteralPath $run.callsPath)) '无效仓库参数应在网络调用之前被拒绝。'
}

# 生产路径：不传 GhCommand，按 PATH 解析 gh。PATH 最前面放转发到替身的 gh.ps1（jq 表达式含引号和管道，
# 经 gh.cmd 的 %* 会被 cmd 重新解析），并先确认解析到它，免得真 gh 发请求。
Assert-Case 'production-gh-resolved-from-path' {
    $pathRoot = Join-Path $fixture 'path-gh'
    $null = [IO.Directory]::CreateDirectory($pathRoot)
    $shim = Join-Path $pathRoot 'gh.ps1'
    [IO.File]::WriteAllText($shim, "& '$($pwsh.Replace("'", "''"))' -NoProfile -NonInteractive -File '$($fakeGh.Replace("'", "''"))' @args`nexit `$LASTEXITCODE`n", $utf8)
    $previousPath = $env:PATH
    $env:PATH = $pathRoot + [IO.Path]::PathSeparator + $env:PATH
    try { $resolved = Get-Command -Name gh | Select-Object -First 1 } finally { $env:PATH = $previousPath }
    Assert-True ($resolved.Source -eq $shim) ('gh 应解析到替身 {0}，实际是 {1}' -f $shim, $resolved.Source)
    $run = Invoke-Case 'production-gh-resolved-from-path' @{ pathRoot = $pathRoot }
    Assert-True ($run.exitCode -eq 0 -and $run.result.status -eq 'ready' -and (Test-Path -LiteralPath $run.callsPath)) '不传 GhCommand 时应按 PATH 解析 gh 并得到 ready。'
}

$failed = @($cases | Where-Object status -eq 'failed').Count
$summary = [ordered]@{
    status = $(if ($failed -eq 0) { 'passed' } else { 'failed' })
    cases = $cases.Count
    results = @($cases | ForEach-Object {
        $item = [ordered]@{ name = $_.name; passed = ($_.status -eq 'passed') }
        if ($_.ContainsKey('message')) { $item.message = $_.message }
        [pscustomobject]$item
    })
}
[IO.File]::WriteAllText((Join-Path $fixture 'result.json'), ($summary | ConvertTo-Json -Depth 6), $utf8)
$summary | ConvertTo-Json -Depth 5 -Compress
if ($failed -gt 0) { exit 1 }
exit 0
