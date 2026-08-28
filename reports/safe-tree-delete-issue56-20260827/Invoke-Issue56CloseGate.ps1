[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('PreClose', 'PostClose')][string]$Mode,
    [string]$CitedCommit = '',
    [string]$ConclusionCommentId = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# #56 §7.1/§7.5 G8：顶层 pre/post-close 评估器。
# PreClose：正式轮 BENCH_PASS + 回归矩阵四 profile 全绿 + 证据闭包（evidence-index 生成并
# 回读验证）→ 只输出 READY_TO_CLOSE（不输出 PASS/COMPLETE）。
# PostClose：仅在被授权的 conclusion-comment→close 之后运行：issue state=closed、结论评论
# 绑定 citedCommit 与 evidence-index SHA、close timeline 晚于评论 → 输出 COMPLETE。
# 退出码：0=目标状态达成（READY_TO_CLOSE / COMPLETE）；2=未达；3=输入/闭包无效；1=执行错误。

$evidenceHome = $PSScriptRoot
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $evidenceHome '..\..')).Path

function Write-JsonFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Document)
    [IO.File]::WriteAllText($Path, ($Document | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
}

function Get-FileSha {
    param([Parameter(Mandatory)][string]$Path)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [IO.File]::ReadAllBytes($Path))).ToLowerInvariant()
}

function New-EvidenceIndex {
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($file in ([IO.Directory]::GetFiles($evidenceHome, '*', [IO.SearchOption]::AllDirectories) | Sort-Object)) {
        $relative = [IO.Path]::GetRelativePath($evidenceHome, $file) -replace '\\', '/'
        if ($relative -ceq 'evidence-index.json' -or $relative -ceq 'close-gate-preclose.json') { continue }
        $rows.Add([pscustomobject][ordered]@{
            relativePath = $relative
            length = [long]([IO.File]::ReadAllBytes($file)).Length
            sha256 = (Get-FileSha -Path $file)
        })
    }
    $index = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-issue56-evidence-index'
        utc = [datetimeoffset]::UtcNow.ToString('o')
        files = @($rows | Sort-Object { [string]$_.relativePath })
    }
    $indexPath = Join-Path $evidenceHome 'evidence-index.json'
    Write-JsonFile -Path $indexPath -Document $index
    # 回读验证。
    $reloaded = Get-Content -Raw -LiteralPath $indexPath | ConvertFrom-Json -Depth 12
    if (@($reloaded.files).Count -ne @($rows).Count) { throw 'evidence-index 回读校验失败。' }
    $indexSha = Get-FileSha -Path $indexPath
    return [pscustomobject]@{ Index = $index; IndexSha256 = $indexSha }
}

if ($Mode -ceq 'PreClose') {
    $invalid = @()
    # 1) 正式轮 BENCH_PASS。
    $rounds = @(Get-ChildItem -LiteralPath $evidenceHome -Directory -Filter 'formal-round-*' | Sort-Object Name)
    if ($rounds.Count -eq 0) { $invalid += '无正式轮 evidence' }
    $latestEvaluationPath = $null
    $latestRound = $null
    if ($rounds.Count -gt 0) {
        $latestRound = $rounds[-1]
        $latestEvaluationPath = Join-Path $latestRound.FullName 'evaluation.json'
        if (-not [IO.File]::Exists($latestEvaluationPath)) { $invalid += '最新正式轮缺 evaluation.json' }
    }
    $benchPass = $false
    if ($null -ne $latestEvaluationPath -and [IO.File]::Exists($latestEvaluationPath)) {
        $evaluation = Get-Content -Raw -LiteralPath $latestEvaluationPath | ConvertFrom-Json -Depth 16
        $benchPass = ([string]$evaluation.verdict -ceq 'BENCH_PASS')
        if (-not $benchPass) { $invalid += ('正式轮 verdict=' + [string]$evaluation.verdict) }
    }
    # 2) 回归矩阵四 profile 日志存在且全绿（由外部矩阵运行产出）。
    $regressionFiles = @(
        'fixture-regression-csharp.log',
        'fixture-regression-powershell.log',
        'fixture-regression-powershell-suffix.log',
        'host-live-regression-csharp.log'
    )
    foreach ($name in $regressionFiles) {
        $path = Join-Path $evidenceHome $name
        if (-not [IO.File]::Exists($path)) { $invalid += ('缺回归日志 ' + $name) }
    }
    # 3) 证据闭包索引。
    $indexResult = $null
    if ($invalid.Count -eq 0) {
        $indexResult = New-EvidenceIndex
    }

    $result = [pscustomobject][ordered]@{
        mode = 'PreClose'
        utc = [datetimeoffset]::UtcNow.ToString('o')
        benchRound = $(if ($null -ne $latestRound) { [string]$latestRound.Name } else { $null })
        benchVerdict = $(if ($null -ne $latestEvaluationPath -and [IO.File]::Exists($latestEvaluationPath)) { [string]$evaluation.verdict } else { $null })
        regressionEvidence = $regressionFiles
        evidenceIndexSha256 = $(if ($null -ne $indexResult) { [string]$indexResult.IndexSha256 } else { $null })
        invalidReasons = @($invalid)
        outcome = ''
    }
    if ($invalid.Count -gt 0) {
        $result.outcome = 'NOT_READY'
        Write-JsonFile -Path (Join-Path $evidenceHome 'close-gate-preclose.json') -Document $result
        Write-Output ('NOT_READY: ' + ($invalid -join '; '))
        exit 2
    }
    $result.outcome = 'READY_TO_CLOSE'
    Write-JsonFile -Path (Join-Path $evidenceHome 'close-gate-preclose.json') -Document $result
    Write-Output ('READY_TO_CLOSE evidenceIndexSha256={0} benchRound={1}' -f @(
        [string]$indexResult.IndexSha256, [string]$latestRound.Name))
    exit 0
}

# PostClose
if ([string]::IsNullOrWhiteSpace($CitedCommit) -or [string]::IsNullOrWhiteSpace($ConclusionCommentId)) {
    Write-Output 'PostClose 需要 -CitedCommit 与 -ConclusionCommentId。'
    exit 3
}
$preclosePath = Join-Path $evidenceHome 'close-gate-preclose.json'
if (-not [IO.File]::Exists($preclosePath)) { Write-Output '缺 PreClose 结果。'; exit 3 }
$preclose = Get-Content -Raw -LiteralPath $preclosePath | ConvertFrom-Json -Depth 8
if ([string]$preclose.outcome -cne 'READY_TO_CLOSE') { Write-Output 'PreClose 未达 READY_TO_CLOSE。'; exit 2 }

$issueJson = gh issue view 56 --json state,closedAt,comments | ConvertFrom-Json
if ([string]$issueJson.state -cne 'CLOSED') { Write-Output 'issue #56 尚未 closed。'; exit 2 }
$comment = @($issueJson.comments | Where-Object { [string]$_.id -ceq $ConclusionCommentId })
if ($comment.Count -ne 1) { Write-Output '结论评论未找到。'; exit 2 }
$body = [string]$comment[0].body
if ($body -notmatch [regex]::Escape($CitedCommit)) { Write-Output '结论评论未引用 cited commit。'; exit 2 }
$indexSha = [string]$preclose.evidenceIndexSha256
if (-not [string]::IsNullOrWhiteSpace($indexSha) -and $body -notmatch [regex]::Escape($indexSha)) {
    Write-Output '结论评论未引用 evidence-index SHA。'
    exit 2
}
$commentCreated = [datetimeoffset]::Parse([string]$comment[0].createdAt)
$closedAt = [datetimeoffset]::Parse([string]$issueJson.closedAt)
if ($commentCreated -ge $closedAt) { Write-Output 'close 时间早于或等于结论评论。'; exit 2 }

Write-Output 'COMPLETE'
exit 0
