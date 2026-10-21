[CmdletBinding()]
param([string]$FixtureRoot = 'D:/agents/run-evidence/github-issue-comment-fixtures')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# scripts\Publish-GitHubIssueComment.ps1 对替身 gh 运行。替身按 FAKE_GH_STATE 指向的 JSON 模拟一个 issue 的
# 评论与标签，并按场景给某类请求注入 EOF：eof-before 表示请求没落地，eof-after 表示已落地但调用方只看到失败。
# 夹具目录复用，各场景只覆盖写单个文件，不递归删除。
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$publishScript = Join-Path $projectRoot 'scripts\Publish-GitHubIssueComment.ps1'
$pwsh = Join-Path $PSHOME 'pwsh.exe'
$utf8 = [Text.UTF8Encoding]::new($false)
$FixtureRoot = [IO.Path]::GetFullPath($FixtureRoot)
[void][IO.Directory]::CreateDirectory($FixtureRoot)
$fakeGhPath = Join-Path $FixtureRoot 'fake-gh.ps1'
$statePath = Join-Path $FixtureRoot 'state.json'
$bodyPath = Join-Path $FixtureRoot 'body.md'
$bodyWithoutMarkerPath = Join-Path $FixtureRoot 'body-without-marker.md'
$marker = 'triage-brief:7:probe:2026-10-21'
$markerComment = '<!-- {0} -->' -f $marker

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

[IO.File]::WriteAllText($fakeGhPath, @'
$ErrorActionPreference = 'Stop'
# 替身 gh：只实现 Publish-GitHubIssueComment.ps1 用到的 REST 调用。输出一律 ASCII-only。
$statePath = $env:FAKE_GH_STATE
$utf8 = [Text.UTF8Encoding]::new($false)
$state = [IO.File]::ReadAllText($statePath, $utf8) | ConvertFrom-Json -AsHashtable
$method = $null
$path = $null
$jq = $null
$paginate = $false
$fields = @{}
for ($i = 1; $i -lt $args.Count; $i++) {
    $token = [string]$args[$i]
    if ($token -ceq '-X') { $i++; $method = [string]$args[$i] }
    elseif ($token -ceq '--paginate') { $paginate = $true }
    elseif ($token -ceq '--jq') { $i++; $jq = [string]$args[$i] }
    elseif ($token -ceq '-F' -or $token -ceq '-f') {
        $i++
        $pair = [string]$args[$i]
        $fields[$pair.Substring(0, $pair.IndexOf('='))] = $pair.Substring($pair.IndexOf('=') + 1)
    }
    else { $path = $token }
}
if ([string]$args[0] -cne 'api' -or $null -eq $path) { [Console]::Error.WriteLine('fake gh: unsupported call'); exit 2 }
# gh api 带字段时默认 POST。
if ($null -eq $method) { $method = $(if ($fields.Count -gt 0) { 'POST' } else { 'GET' }) }
$route = switch -Regex ($method + ' ' + $path) {
    '^GET repos/fixture/repo/issues/7$' { 'get-issue'; break }
    '^GET repos/fixture/repo/issues/7/comments\?per_page=100$' { 'list-comments'; break }
    '^POST repos/fixture/repo/issues/7/comments$' { 'post-comment'; break }
    '^POST repos/fixture/repo/issues/7/labels$' { 'add-label'; break }
    '^DELETE repos/fixture/repo/issues/7/labels/[^/]+$' { 'delete-label'; break }
    default { 'unsupported' }
}
$failure = @($state['failures'] | Where-Object { $_['route'] -eq $route -and $_['remaining'] -gt 0 }) | Select-Object -First 1
if ($null -ne $failure) { $failure['remaining'] = $failure['remaining'] - 1 }
$stdout = @()
$exitCode = 0
if ($null -eq $failure -or $failure['mode'] -eq 'eof-after') {
    switch ($route) {
        'get-issue' {
            $issue = [ordered]@{ number = $state['issue']['number']; state = 'open'; labels = @($state['issue']['labels'] | ForEach-Object { [ordered]@{ name = $_ } }) }
            $stdout = @($issue | ConvertTo-Json -Compress -Depth 4 -EscapeHandling EscapeNonAscii)
        }
        'list-comments' {
            if (-not $paginate -or $jq -cne '.[] | {html_url, body}') { [Console]::Error.WriteLine('fake gh: unexpected list options'); exit 3 }
            $stdout = @($state['comments'] | ForEach-Object { [ordered]@{ html_url = $_['html_url']; body = $_['body'] } | ConvertTo-Json -Compress -EscapeHandling EscapeNonAscii })
        }
        'post-comment' {
            $id = $state['nextId']
            $state['nextId'] = $id + 1
            $comment = [ordered]@{ html_url = ('https://github.com/fixture/repo/issues/7#issuecomment-{0}' -f $id); body = [IO.File]::ReadAllText($fields['body'].Substring(1), $utf8) }
            $state['comments'] = @($state['comments']) + @($comment)
            $stdout = @($comment | ConvertTo-Json -Compress -EscapeHandling EscapeNonAscii)
        }
        'add-label' {
            if ($state['issue']['labels'] -notcontains $fields['labels[]']) { $state['issue']['labels'] = @($state['issue']['labels']) + @($fields['labels[]']) }
            $stdout = @('[]')
        }
        'delete-label' {
            $label = [Uri]::UnescapeDataString($path.Substring($path.LastIndexOf('/') + 1))
            if ($state['issue']['labels'] -contains $label) { $state['issue']['labels'] = @($state['issue']['labels'] | Where-Object { $_ -ne $label }) }
            else { [Console]::Error.WriteLine('gh: Label does not exist (HTTP 404)'); $exitCode = 1 }
        }
        default { [Console]::Error.WriteLine('fake gh: unsupported route'); $exitCode = 2 }
    }
}
if ($null -ne $failure) {
    $stdout = @()
    [Console]::Error.WriteLine(('{0} "https://api.github.com/{1}": EOF' -f $method, $path))
    $exitCode = 1
}
$state['calls'] = @($state['calls']) + @($route)
[IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 8 -EscapeHandling EscapeNonAscii), $utf8)
foreach ($line in $stdout) { [Console]::Out.WriteLine($line) }
exit $exitCode
'@, $utf8)
[IO.File]::WriteAllText($bodyPath, "> 测试评论`n`n第二段：含中文与 ``代码``。`n`n$markerComment`n", $utf8)
[IO.File]::WriteAllText($bodyWithoutMarkerPath, "> 没有 marker 的评论`n", $utf8)

function Set-FakeState([object[]]$Comments = @(), [object[]]$Failures = @()) {
    $state = [ordered]@{
        issue = [ordered]@{ number = 7; labels = @('enhancement', 'needs-triage') }
        comments = @($Comments)
        nextId = 100
        failures = @($Failures)
        calls = @()
    }
    [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 8 -EscapeHandling EscapeNonAscii), $utf8)
}

function Get-FakeState {
    return ([IO.File]::ReadAllText($statePath, $utf8) | ConvertFrom-Json -AsHashtable)
}

function Get-CallCount($State, [string]$Route) {
    return @($State['calls'] | Where-Object { $_ -eq $Route }).Count
}

function Get-MarkerCount($State) {
    return @($State['comments'] | Where-Object { ([string]$_['body']).Contains($markerComment) }).Count
}

function Invoke-Publish([hashtable]$Override = @{}) {
    $parameters = @{
        Number = 7
        BodyPath = $bodyPath
        Marker = $marker
        Repository = 'fixture/repo'
        AddLabels = @('ready-for-agent')
        RemoveLabels = @('needs-triage')
        GhCommandForTest = @($pwsh, '-NoProfile', '-NonInteractive', '-File', $fakeGhPath)
        NoRetryDelayForTest = $true
    }
    foreach ($key in $Override.Keys) { $parameters[$key] = $Override[$key] }
    $previous = $env:FAKE_GH_STATE
    $env:FAKE_GH_STATE = $statePath
    try {
        $output = @(& $publishScript @parameters)
        $exitCode = $LASTEXITCODE
    } finally {
        $env:FAKE_GH_STATE = $previous
    }
    Assert-True ($output.Count -eq 1) ('脚本应只输出一行 JSON：{0}' -f ($output -join ' | '))
    return [pscustomobject]@{ exitCode = $exitCode; result = ([string]$output[0] | ConvertFrom-Json -AsHashtable); text = [string]$output[0] }
}

function Assert-Published($Run, [string]$Via, [string]$Scenario) {
    Assert-True ($Run.exitCode -eq 0 -and $Run.result['ok'] -eq $true -and $Run.result['commentVia'] -eq $Via) ('{0}：应成功且 commentVia={1}：{2}' -f $Scenario, $Via, $Run.text)
    $state = Get-FakeState
    Assert-True ((Get-MarkerCount $state) -eq 1) ('{0}：带 marker 的评论应恰好一条：{1}' -f $Scenario, $Run.text)
    $labels = @($state['issue']['labels'])
    Assert-True ($labels -contains 'ready-for-agent' -and $labels -notcontains 'needs-triage' -and $labels -contains 'enhancement') ('{0}：标签不对：{1}' -f $Scenario, ($labels -join ','))
    return $state
}

# 首次发布：发一条评论，加 ready-for-agent、删 needs-triage，不动其他标签；正文原样落地。
Set-FakeState
$run = Invoke-Publish
$state = Assert-Published $run 'posted' '首次发布'
Assert-True ((Get-CallCount $state 'post-comment') -eq 1) '首次发布应只发一次评论。'
Assert-True ($run.result['commentUrl'] -eq 'https://github.com/fixture/repo/issues/7#issuecomment-100') ('commentUrl 不对：{0}' -f $run.text)
Assert-True (@($state['comments'])[0]['body'] -ceq [IO.File]::ReadAllText($bodyPath, $utf8)) '评论正文应与文件逐字一致。'

# 重跑：评论已在，不再发；标签已符合要求。
$run = Invoke-Publish
$state = Assert-Published $run 'already-present' '重跑'
Assert-True ((Get-CallCount $state 'post-comment') -eq 1) '重跑不应再发评论。'

# 读取 issue 时 EOF 一次：重试后照常完成。
Set-FakeState -Failures @([ordered]@{ route = 'get-issue'; mode = 'eof-before'; remaining = 1 })
$state = Assert-Published (Invoke-Publish) 'posted' '读取 EOF 一次'
Assert-True ((Get-CallCount $state 'get-issue') -eq 3) '读取 EOF 后应重试一次（前后两次快照共 3 次读取）。'

# 发评论报 EOF 但请求已落地：回读看到 marker，不重发。
Set-FakeState -Failures @([ordered]@{ route = 'post-comment'; mode = 'eof-after'; remaining = 1 })
$state = Assert-Published (Invoke-Publish) 'landed-despite-error' '发评论 EOF 但已落地'
Assert-True ((Get-CallCount $state 'post-comment') -eq 1) '已落地时不应重发。'

# 发评论报 EOF 且没落地：回读确认没有后重发一次。
Set-FakeState -Failures @([ordered]@{ route = 'post-comment'; mode = 'eof-before'; remaining = 1 })
$state = Assert-Published (Invoke-Publish) 'posted-after-recheck' '发评论 EOF 且未落地'
Assert-True ((Get-CallCount $state 'post-comment') -eq 2) '未落地时应恰好重发一次。'

# 两次发评论都没落地：失败退出，不发第三次，也不改标签。
Set-FakeState -Failures @([ordered]@{ route = 'post-comment'; mode = 'eof-before'; remaining = 5 })
$run = Invoke-Publish
$state = Get-FakeState
Assert-True ($run.exitCode -eq 1 -and $run.result['ok'] -eq $false -and $null -ne $run.result['error']) ('两次都失败时应以 1 退出并给出 error：{0}' -f $run.text)
Assert-True ((Get-CallCount $state 'post-comment') -eq 2 -and (Get-MarkerCount $state) -eq 0) '最多发两次评论。'
Assert-True (@($state['issue']['labels']) -contains 'needs-triage' -and (Get-CallCount $state 'add-label') -eq 0) '评论没发出时不应改标签。'

# 读取一直失败：重试用完后失败闭锁，不发评论。
Set-FakeState -Failures @([ordered]@{ route = 'get-issue'; mode = 'eof-before'; remaining = 99 })
$run = Invoke-Publish
$state = Get-FakeState
Assert-True ($run.exitCode -eq 1 -and $run.result['ok'] -eq $false) ('读取一直失败时应以 1 退出：{0}' -f $run.text)
Assert-True ((Get-CallCount $state 'get-issue') -eq 4 -and (Get-CallCount $state 'post-comment') -eq 0) '读取应重试 4 次后放弃，且不发评论。'

# 删标签报 EOF 但已生效：回读确认标签已不在，不再重试。
Set-FakeState -Failures @([ordered]@{ route = 'delete-label'; mode = 'eof-after'; remaining = 1 })
$state = Assert-Published (Invoke-Publish) 'posted' '删标签 EOF 但已生效'
Assert-True ((Get-CallCount $state 'delete-label') -eq 1) '标签已删掉时不应重试删除。'

# 已有两条带同一 marker 的评论：拒绝处理，交给人。
$duplicate = [ordered]@{ html_url = 'https://github.com/fixture/repo/issues/7#issuecomment-1'; body = $markerComment }
Set-FakeState -Comments @($duplicate, $duplicate)
$run = Invoke-Publish
$state = Get-FakeState
Assert-True ($run.exitCode -eq 1 -and $run.result['ok'] -eq $false) ('重复 marker 时应以 1 退出：{0}' -f $run.text)
Assert-True ((Get-CallCount $state 'post-comment') -eq 0 -and (Get-CallCount $state 'delete-label') -eq 0) '重复 marker 时不应发评论或改标签。'

# 正文缺 marker：不调用 gh。
Set-FakeState
$run = Invoke-Publish @{ BodyPath = $bodyWithoutMarkerPath }
Assert-True ($run.exitCode -eq 1 -and $run.result['ok'] -eq $false) ('正文缺 marker 时应以 1 退出：{0}' -f $run.text)
Assert-True (@((Get-FakeState)['calls']).Count -eq 0) '正文缺 marker 时不应调用 gh。'

'publish github issue comment: all checks passed'
