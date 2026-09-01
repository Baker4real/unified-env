[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Seams under test (GitHub #57):
# 1. Leftover root — Phase3 leftover guard observes D:\agents\run-evidence\safe-tree-delete.
#    If that directory exists, leftoverGuardMode=production-host and leftover assertions run.
# 2. Ephemeral write — representative suite fixture roots go under gitignored
#    project .scratch/safe-tree-delete-tests-*; tracked reports/ stays clean.
# Frozen reports/safe-tree-delete-issue* remain inputs. Not production Purge.

$projectRoot = Split-Path -Parent $PSScriptRoot
$expectedLeftoverRoot = 'D:\agents\run-evidence\safe-tree-delete'
$expectedLeftoverTx = Join-Path $expectedLeftoverRoot '20260816T021845Z-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e\transaction.json'
$phase3Path = Join-Path $PSScriptRoot 'Test-CodexSafeTreeDeletePhase3Integration.ps1'

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-AssignmentValue {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Name
    )
    $pattern = '(?m)^\$' + [regex]::Escape($Name) + ' = (.+)$'
    $match = [regex]::Match($Text, $pattern)
    Assert-True $match.Success "必须赋值 `$$Name"
    return $match.Groups[1].Value.Trim()
}

Assert-True (Test-Path -LiteralPath $phase3Path -PathType Leaf) 'Phase3Integration 测试必须存在'
$phase3Text = [IO.File]::ReadAllText($phase3Path)

$productionAssign = Get-AssignmentValue -Text $phase3Text -Name 'productionRunEvidenceRoot'
Assert-True ($productionAssign -ceq "'$expectedLeftoverRoot'") (
    "Phase3 productionRunEvidenceRoot 必须是 $expectedLeftoverRoot，实际为 $productionAssign")

$leftoverAssign = Get-AssignmentValue -Text $phase3Text -Name 'leftoverEvidenceRoot'
Assert-True (
    $leftoverAssign -ceq '$productionRunEvidenceRoot' -or
    $leftoverAssign -ceq "'$expectedLeftoverRoot'"
) (
    "Phase3 leftoverEvidenceRoot 必须观察迁移后的生产根 $expectedLeftoverRoot，实际为 $leftoverAssign")
Assert-True ($leftoverAssign -notmatch 'Codex\\?\.codex\\?run-evidence') (
    "Phase3 leftoverEvidenceRoot 不得指向已迁移走的 Codex run-evidence 根，实际为 $leftoverAssign")

$observedLeftoverRoot = if ($leftoverAssign -ceq '$productionRunEvidenceRoot') {
    $expectedLeftoverRoot
} else {
    $leftoverAssign.Trim("'")
}
$leftoverGuardMode = if ([IO.Directory]::Exists($observedLeftoverRoot)) {
    'production-host'
} else {
    'absent-environment'
}
Write-Output ("leftoverGuardMode=$leftoverGuardMode leftoverEvidenceRoot=$observedLeftoverRoot")
if ([IO.Directory]::Exists($expectedLeftoverRoot)) {
    Assert-True ($leftoverGuardMode -ceq 'production-host') (
        "本机生产 leftover 根存在时 leftoverGuardMode 必须是 production-host，实际为 $leftoverGuardMode root=$observedLeftoverRoot")
    Assert-True ([IO.File]::Exists($expectedLeftoverTx)) (
        "本机生产 leftover transaction.json 必须存在: $expectedLeftoverTx")
} else {
    Assert-True ($leftoverGuardMode -ceq 'absent-environment') (
        "生产 leftover 根不存在时 leftoverGuardMode 必须是 absent-environment，实际为 $leftoverGuardMode")
}

Assert-True ($phase3Text.Contains('[IO.Directory]::Exists($leftoverEvidenceRoot)')) (
    'leftoverGuardMode 必须按 leftoverEvidenceRoot 是否存在判定，而不是 CI 环境变量')

$scratchHelperPath = Join-Path $PSScriptRoot 'New-CodexSafeTreeDeleteTestScratchRoot.ps1'
Assert-True (Test-Path -LiteralPath $scratchHelperPath -PathType Leaf) 'scratch 写根 helper 必须存在'
$scratchHelperText = [IO.File]::ReadAllText($scratchHelperPath)
Assert-True ($scratchHelperText.Contains("safe-tree-delete-tests-")) (
    'scratch helper 必须把写根固定在 .scratch/safe-tree-delete-tests-*')

function Assert-ScratchHelperAssignment {
    param(
        [Parameter(Mandatory)][string]$ScriptName,
        [Parameter(Mandatory)][string]$VariableName
    )
    $scriptPath = Join-Path $PSScriptRoot $ScriptName
    Assert-True (Test-Path -LiteralPath $scriptPath -PathType Leaf) "$ScriptName 必须存在"
    $text = [IO.File]::ReadAllText($scriptPath)
    $assign = Get-AssignmentValue -Text $text -Name $VariableName
    Assert-True ($assign.Contains('New-CodexSafeTreeDeleteTestScratchRoot')) (
        "$ScriptName `$$VariableName 必须经 scratch helper 分配，实际为 $assign")
    Assert-True ($assign -notmatch 'reports\\safe-tree-delete-issue') (
        "$ScriptName `$$VariableName 不得写入 tracked issue 快照，实际为 $assign")
    Assert-True ($assign -notmatch 'reports\\safe-tree-delete-parallelism-benchmark') (
        "$ScriptName `$$VariableName 不得写入 tracked parallelism-benchmark 快照，实际为 $assign")
}

Assert-ScratchHelperAssignment -ScriptName 'Test-CodexSafeTreeDeleteThreadJournal.ps1' -VariableName 'evidenceHome'
Assert-ScratchHelperAssignment -ScriptName 'Test-CodexSafeTreeDeleteHashReuse.ps1' -VariableName 'evidenceHome'
Assert-ScratchHelperAssignment -ScriptName 'Test-CodexSafeTreeDeletePurgeHashReuse.ps1' -VariableName 'evidenceHome'
Assert-ScratchHelperAssignment -ScriptName 'Test-CodexSafeTreeDeleteUncertainRecovery.ps1' -VariableName 'evidenceHome'
Assert-ScratchHelperAssignment -ScriptName 'Test-CodexSafeTreeDeletePhase1Integration.ps1' -VariableName 'evidenceHome'
Assert-ScratchHelperAssignment -ScriptName 'Test-CodexSafeTreeDeletePurgeBatch.ps1' -VariableName 'evidenceHome'
Assert-ScratchHelperAssignment -ScriptName 'Test-CodexSafeTreeDeleteParallelPurgeCoordinator.ps1' -VariableName 'evidenceHome'
Assert-ScratchHelperAssignment -ScriptName 'Test-CodexSafeTreeDeleteJournalPerformance.ps1' -VariableName 'evidenceHome'
Assert-ScratchHelperAssignment -ScriptName 'Test-CodexSafeTreeDeletePhase3Integration.ps1' -VariableName 'evidenceHome'
Assert-ScratchHelperAssignment -ScriptName 'Test-CodexSafeTreeDeletePhase3Production.ps1' -VariableName 'evidenceHome'
Assert-ScratchHelperAssignment -ScriptName 'Test-CodexSafeTreeDeleteParallelismBenchmark.ps1' -VariableName 'defaultEvidenceHome'
Assert-ScratchHelperAssignment -ScriptName 'Test-CodexSafeTreeDeleteProductionSmoke.ps1' -VariableName 'scratchRoot'

$smokePath = Join-Path $PSScriptRoot 'Test-CodexSafeTreeDeleteProductionSmoke.ps1'
$smokeText = [IO.File]::ReadAllText($smokePath)
$failAssign = Get-AssignmentValue -Text $smokeText -Name 'failFixtureRoot'
$issue21FailAssign = Get-AssignmentValue -Text $smokeText -Name 'issue21FailFixtureRoot'
Assert-True ($failAssign.Contains('$scratchRoot')) (
    "ProductionSmoke issue55 livefail 必须写在 scratchRoot 下，实际为 $failAssign")
Assert-True ($issue21FailAssign.Contains('$scratchRoot')) (
    "ProductionSmoke issue21 livefail 必须写在 scratchRoot 下，实际为 $issue21FailAssign")
Assert-True ($failAssign -notmatch 'reportsRoot') (
    "ProductionSmoke issue55 livefail 不得写入 reports/，实际为 $failAssign")
Assert-True ($issue21FailAssign -notmatch 'reportsRoot') (
    "ProductionSmoke issue21 livefail 不得写入 reports/，实际为 $issue21FailAssign")

function Get-ReportsGitStatus {
    $git = Get-Command git -ErrorAction Stop
    $output = & $git.Source -C $projectRoot --no-optional-locks status --short -- reports/
    if ($LASTEXITCODE -ne 0) {
        throw "git status -- reports/ failed with exit $LASTEXITCODE"
    }
    $rows = [Collections.Generic.List[string]]::new()
    foreach ($line in @($output)) {
        $text = [string]$line
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            $rows.Add($text)
        }
    }
    return , $rows
}

$threadJournalPath = Join-Path $PSScriptRoot 'Test-CodexSafeTreeDeleteThreadJournal.ps1'
$pwshExe = (Get-Command pwsh -ErrorAction Stop).Source
$reportsBefore = Get-ReportsGitStatus
& $pwshExe -NoProfile -NonInteractive -File $threadJournalPath
if ($LASTEXITCODE -ne 0) {
    throw "ThreadJournal residue run failed with exit $LASTEXITCODE"
}
$reportsAfter = Get-ReportsGitStatus
Assert-True ($reportsAfter.Count -eq 0) (
    "ThreadJournal 后 tracked reports/ 必须保持干净: $($reportsAfter -join '; ')")
Assert-True ($reportsBefore.Count -eq $reportsAfter.Count) (
    'ThreadJournal 不得新增 reports/ 脏项')

[pscustomobject][ordered]@{
    ok = $true
    suite = 'CodexSafeTreeDeleteScratchResidue'
    leftoverGuardMode = $leftoverGuardMode
    leftoverEvidenceRoot = $observedLeftoverRoot
    leftoverAssertionsEnforced = ($leftoverGuardMode -ceq 'production-host')
}
