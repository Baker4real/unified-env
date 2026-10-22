[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$Number,
    # 评论正文文件（UTF-8），必须含 <!-- Marker -->。
    [Parameter(Mandatory)][string]$BodyPath,
    # 本条评论唯一的隐藏标记，用来判断评论是否已经发出。
    [Parameter(Mandatory)][string]$Marker,
    [string[]]$AddLabels = @(),
    [string[]]$RemoveLabels = @(),
    # owner/name；缺省时 gh 按仓库根的 git remote 填 {owner}/{repo}。
    [string]$Repository = '{owner}/{repo}',
    # 测试专用 seam（生产调用不传）：替身 gh 命令（可执行文件加前置参数）与零等待重试。
    [string[]]$GhCommandForTest,
    [switch]$NoRetryDelayForTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# gh 的退出码由本脚本判断：读取重试，写入先回读再决定是否重发。
$PSNativeCommandUseErrorActionPreference = $false
$utf8 = [Text.UTF8Encoding]::new($false)
# 按 UTF-8 解码 gh 的输出（评论正文含中文）。
[Console]::OutputEncoding = $utf8
. (Join-Path $PSScriptRoot 'lib\GitHubCli.ps1')

# 幂等地给 issue 发一条带隐藏 marker 的评论，并按需加、删标签；规则见
# docs/agents/issue-tracker.md「gh 报 EOF 时」。全部走 REST。发评论失败时请求可能已经落地，
# 所以先回读、按 marker 判断，确认没有才重发，最多发两次。结束时回读核验：
# 带 marker 的评论恰好一条、标签符合要求时退出 0，否则退出 1。输出一行 ASCII-only JSON。

$projectRoot = Split-Path -Parent $PSScriptRoot
# 下面会切到仓库根运行 gh，相对路径先按调用方的当前位置解析。
$BodyPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BodyPath)
# 用 @() 让只有 'gh' 一个元素时仍是数组；$() 会把它展开成字符串，下面取 [0] 就只剩 'g'。
$ghCommand = @(if ($null -ne $GhCommandForTest -and $GhCommandForTest.Count -gt 0) { $GhCommandForTest } else { 'gh' })
$markerComment = '<!-- {0} -->' -f $Marker
$issuePath = 'repos/{0}/issues/{1}' -f $Repository, $Number
$attemptLimit = 4

function Wait-BeforeRetry([int]$Seconds) {
    if (-not $NoRetryDelayForTest) { Start-Sleep -Seconds $Seconds }
}

function Get-IssueSnapshot {
    $issue = (Invoke-GhWithRetry -GhCommand $ghCommand -Arguments @('api', $issuePath) -NoRetryDelay:$NoRetryDelayForTest) -join "`n" | ConvertFrom-Json -AsHashtable
    if ($null -eq $issue -or $issue['number'] -ne $Number) {
        throw ('issue read returned no data for #{0}' -f $Number)
    }
    $lines = @(Invoke-GhWithRetry -GhCommand $ghCommand -Arguments @('api', '--paginate', ($issuePath + '/comments?per_page=100'), '--jq', '.[] | {html_url, body}') -NoRetryDelay:$NoRetryDelayForTest)
    $markerComments = @($lines | Where-Object { $_.Length -gt 0 } | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable } |
        Where-Object { ([string]$_['body']).Contains($markerComment) })
    return [pscustomobject]@{
        labels = @($issue['labels'] | ForEach-Object { [string]$_['name'] })
        markerCount = $markerComments.Count
        commentUrl = $(if ($markerComments.Count -gt 0) { [string]$markerComments[-1]['html_url'] } else { $null })
    }
}

function Remove-IssueLabel([string]$Label) {
    $labelPath = '{0}/labels/{1}' -f $issuePath, [Uri]::EscapeDataString($Label)
    for ($attempt = 1; ; $attempt++) {
        $result = Invoke-Gh -GhCommand $ghCommand -Arguments @('api', '-X', 'DELETE', $labelPath)
        if ($result.exitCode -eq 0) { return }
        # 失败时回读：标签已经不在就算完成（含请求其实已生效的情况）。
        if ((Get-IssueSnapshot).labels -notcontains $Label) { return }
        if ($attempt -ge $attemptLimit) {
            throw ('removing label {0} failed after {1} attempts (exit {2}): {3}' -f $Label, $attempt, $result.exitCode, $result.stderr)
        }
        Wait-BeforeRetry (2 * $attempt)
    }
}

$summary = [ordered]@{
    ok = $false
    number = $Number
    marker = $Marker
    commentVia = $null
    markerCommentCount = $null
    commentUrl = $null
    labelsBefore = $null
    labelsAfter = $null
    error = $null
}
Push-Location -LiteralPath $projectRoot
try {
    if ($Marker -cnotmatch '^[A-Za-z0-9][A-Za-z0-9:._/-]{0,199}\z' -or $Marker.Contains('--')) {
        throw 'Marker may only contain letters, digits and : . _ / -, must not contain --, and is at most 200 characters'
    }
    $body = [IO.File]::ReadAllText($BodyPath, $utf8)
    if (-not $body.Contains($markerComment)) { throw ('comment body does not contain {0}' -f $markerComment) }
    if (@(@($AddLabels) + @($RemoveLabels) | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        throw 'label names must not be empty'
    }
    $conflicting = @($AddLabels | Where-Object { $_ -in $RemoveLabels })
    if ($conflicting.Count -gt 0) { throw ('labels both added and removed: {0}' -f ($conflicting -join ', ')) }

    $before = Get-IssueSnapshot
    $summary.labelsBefore = $before.labels
    if ($before.markerCount -gt 1) {
        throw ('{0} comments already carry this marker; resolve the duplicates by hand' -f $before.markerCount)
    }
    if ($before.markerCount -eq 1) {
        $summary.commentVia = 'already-present'
    } else {
        $summary.commentVia = 'posted'
        for ($attempt = 1; ; $attempt++) {
            $post = Invoke-Gh -GhCommand $ghCommand -Arguments @('api', ($issuePath + '/comments'), '-F', ('body=@' + $BodyPath))
            if ($post.exitCode -eq 0) { break }
            # 失败的请求可能已经落地：先回读，再决定是否重发。
            Wait-BeforeRetry 3
            if ((Get-IssueSnapshot).markerCount -ge 1) {
                $summary.commentVia = 'landed-despite-error'
                break
            }
            if ($attempt -ge 2) {
                throw ('posting the comment failed twice (exit {0}): {1}' -f $post.exitCode, $post.stderr)
            }
            $summary.commentVia = 'posted-after-recheck'
        }
    }

    # 加标签是幂等的，可以直接重试。
    foreach ($label in $AddLabels) {
        if ($before.labels -notcontains $label) {
            [void](Invoke-GhWithRetry -GhCommand $ghCommand -Arguments @('api', ($issuePath + '/labels'), '-f', ('labels[]=' + $label)) -NoRetryDelay:$NoRetryDelayForTest)
        }
    }
    foreach ($label in $RemoveLabels) {
        if ($before.labels -contains $label) { Remove-IssueLabel $label }
    }

    $after = Get-IssueSnapshot
    $summary.labelsAfter = $after.labels
    $summary.markerCommentCount = $after.markerCount
    $summary.commentUrl = $after.commentUrl
    if ($after.markerCount -ne 1) { throw ('read back {0} comments carrying the marker, expected 1' -f $after.markerCount) }
    $missing = @($AddLabels | Where-Object { $after.labels -notcontains $_ })
    $lingering = @($RemoveLabels | Where-Object { $after.labels -contains $_ })
    if ($missing.Count -gt 0 -or $lingering.Count -gt 0) {
        throw ('labels not as requested; missing: {0}; still present: {1}' -f ($missing -join ', '), ($lingering -join ', '))
    }
    $summary.ok = $true
} catch {
    $summary.error = $_.Exception.Message
} finally {
    Pop-Location
}

[pscustomobject]$summary | ConvertTo-Json -Compress -Depth 4 -EscapeHandling EscapeNonAscii
exit $(if ($summary.ok) { 0 } else { 1 })
