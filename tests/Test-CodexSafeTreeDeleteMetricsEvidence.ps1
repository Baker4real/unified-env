[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$benchmarkPath = Join-Path $projectRoot 'scripts\Measure-CodexSafeTreeDelete.ps1'
$hostSafetyLibraryPath = Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1'
$outputPath = Join-Path $projectRoot (
    "reports\safe-tree-delete-metrics-evidence-test-{0}.json" -f [guid]::NewGuid().ToString('N'))
$outputBaseName = [IO.Path]::GetFileNameWithoutExtension($outputPath)
$retainedEvidenceRoot = Join-Path (Split-Path -Parent $outputPath) "$outputBaseName-evidence"
$retainedEvidencePath = Join-Path $retainedEvidenceRoot 'benchmark-evidence.json'

. $hostSafetyLibraryPath

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Remove-TestEvidenceTree {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.Directory]::Exists($Path)) { return }
    $snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot `
        -Path $Path `
        -CapabilityRoot (Split-Path -Parent $Path) `
        -AllowedExactPaths @($Path) `
        -Name 'safe-delete metrics evidence cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot (Split-Path -Parent $Path) `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'safe-delete metrics evidence cleanup'
}

function Assert-MetricsContract {
    param([Parameter(Mandatory)][object]$Metrics, [Parameter(Mandatory)][string]$Phase)

    Assert-True (
        ((@($Metrics.PSObject.Properties.Name) -join '|') -ceq
            'schemaVersion|phase|elapsedMs|entriesScanned|logicalBytes|bytesHashed|retry')) `
        "$Phase metrics 属性结构必须稳定"
    Assert-True ($Metrics.schemaVersion -eq 1 -and [string]$Metrics.phase -ceq $Phase) `
        "$Phase metrics 必须使用统一版本和 phase"
    Assert-True ($Metrics.elapsedMs -is [long] -and [long]$Metrics.elapsedMs -ge 0L) `
        "$Phase elapsedMs 必须是非负 integer"
    Assert-True (
        ((@($Metrics.retry.PSObject.Properties.Name) -join '|') -ceq
            'contract|attempts|result|events')) `
        "$Phase retry metrics 属性结构必须稳定"
    Assert-True ($Metrics.retry.attempts -is [long] -and [long]$Metrics.retry.attempts -ge 0L) `
        "$Phase retry attempts 必须是非负 integer"
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$Metrics.retry.result)) `
        "$Phase retry result 不得静默缺失"
}

try {
    & $benchmarkPath `
        -OutputPath $outputPath `
        -SmallDatasetBytes 256 `
        -LargeDatasetBytes 512 | Out-Null

    $report = Get-Content -Raw -LiteralPath $outputPath |
        ConvertFrom-Json -Depth 128 -DateKind String -ErrorAction Stop
    Assert-True ($report.schemaVersion -eq 2) 'metrics evidence summary schema 必须稳定'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$report.capturedAtUtc)) `
        'metrics evidence summary 必须记录 capturedAtUtc'
    Assert-True ($report.artifacts.sourceLibrarySha256 -match '^[0-9a-f]{64}$' -and
        $report.artifacts.sourceWrapperSha256 -match '^[0-9a-f]{64}$' -and
        $report.artifacts.sourceHostAdapterSha256 -match '^[0-9a-f]{64}$') `
        'metrics evidence summary 必须记录 source artifact SHA-256'
    Assert-True (
        ($report.artifacts.liveWrapperSha256 -match '^[0-9a-f]{64}$') -or
        ($null -eq $report.artifacts.liveWrapperSha256 -and
            [string]$report.artifacts.liveWrapperStatus -ceq 'not-checked')) `
        'metrics evidence summary 必须显式记录 live artifact SHA-256 或未检查状态'
    Assert-True ($report.execution.exitCode -eq 0 -and
        [string]$report.execution.exitStatus -ceq 'succeeded') `
        'metrics evidence summary 必须记录实际成功退出语义'
    Assert-True ([string]$report.execution.command -match [regex]::Escape($benchmarkPath) -and
        [string]$report.execution.command -match '-SmallDatasetBytes 256' -and
        [string]$report.execution.command -match '-LargeDatasetBytes 512') `
        'metrics evidence summary 必须记录完整可复现命令'
    Assert-True ([string]$report.retainedEvidence.path -ceq $retainedEvidencePath -and
        $report.retainedEvidence.sha256 -match '^[0-9a-f]{64}$' -and
        $report.retainedEvidence.payloadBytesRetained -eq $false) `
        'metrics evidence summary 必须引用不含 payload 的 retained evidence'
    Assert-True ([IO.File]::Exists($retainedEvidencePath)) 'retained evidence 必须实际存在'
    Assert-True (
        ((Get-FileHash -LiteralPath $retainedEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq
            [string]$report.retainedEvidence.sha256)) `
        'metrics evidence summary 必须绑定 retained evidence 精确 bytes'

    $evidence = Get-Content -Raw -LiteralPath $retainedEvidencePath |
        ConvertFrom-Json -Depth 128 -DateKind String -ErrorAction Stop
    Assert-True ($evidence.artifactType -ceq
        'env-governance.codex-safe-tree-delete-benchmark-evidence' -and
        $evidence.schemaVersion -eq 1 -and $evidence.payloadBytesRetained -eq $false) `
        'retained evidence 合同必须稳定且不得保留 payload bytes'
    Assert-True (@($report.datasets).Count -eq 2 -and @($evidence.datasets).Count -eq 2) `
        'metrics evidence 必须同时保留两次同结构 fixture 摘要'

    $metricShapes = [Collections.Generic.List[string]]::new()
    foreach ($dataset in @($report.datasets)) {
        Assert-True ($dataset.policySha256 -match '^[0-9a-f]{64}$') `
            '每个 fixture 必须记录 policy SHA-256'
        Assert-MetricsContract -Metrics $dataset.plan.metrics -Phase 'plan'
        Assert-MetricsContract -Metrics $dataset.status.metrics -Phase 'status'
        Assert-MetricsContract -Metrics $dataset.apply.metrics -Phase 'apply'
        Assert-MetricsContract -Metrics $dataset.restore.metrics -Phase 'restore'
        Assert-MetricsContract -Metrics $dataset.purge.metrics -Phase 'purge'
        Assert-True ($dataset.fixture.logicalBytes -eq $dataset.payloadBytes -and
            $dataset.plan.metrics.logicalBytes -eq $dataset.payloadBytes -and
            $dataset.status.metrics.logicalBytes -eq $dataset.payloadBytes -and
            $dataset.apply.metrics.logicalBytes -eq $dataset.payloadBytes -and
            $dataset.purge.metrics.logicalBytes -eq $dataset.payloadBytes) `
            'metrics evidence 必须区分并精确记录 dataset logical bytes'
        Assert-True ($dataset.purge.deletionOutcome.namespaceAbsent -eq $true -and
            $dataset.purge.deletionOutcome.logicalCompletion -eq $true -and
            $dataset.purge.deletionOutcome.physicalReclaimStatus -ceq 'unknown') `
            'metrics evidence 不得把 namespace absence 冒充 physical reclaim'
        $metricShapes.Add((@($dataset.plan.metrics.PSObject.Properties.Name) -join '|'))

        $evidenceDataset = @($evidence.datasets | Where-Object name -CEQ $dataset.name)
        Assert-True ($evidenceDataset.Count -eq 1) 'retained evidence dataset 必须唯一'
        $requiredStages = @(
            'plan', 'status-planned', 'apply', 'status-recoverable', 'restore',
            'purge-plan', 'purge-apply', 'purge', 'status-terminal')
        foreach ($stageName in $requiredStages) {
            $stage = @($evidenceDataset[0].stages | Where-Object name -CEQ $stageName)
            Assert-True ($stage.Count -eq 1) "retained evidence 必须包含唯一阶段：$stageName"
            Assert-True ([string]$stage[0].invocation.scriptPath -ceq
                (Join-Path $projectRoot 'tests\Invoke-CodexSafeTreeDeleteFixture.ps1')) `
                "阶段必须记录 public script seam：$stageName"
            Assert-True (@($stage[0].invocation.parameters.PSObject.Properties).Count -gt 0 -and
                -not [string]::IsNullOrWhiteSpace([string]$stage[0].invocation.command)) `
                "阶段必须记录 exact invocation：$stageName"
            Assert-True ($stage[0].exitCode -eq 0 -and
                [string]$stage[0].exitStatus -ceq 'succeeded' -and $null -ne $stage[0].result) `
                "阶段必须记录真实成功结果：$stageName"
        }
    }
    Assert-True ($metricShapes[0] -ceq $metricShapes[1]) `
        '重复 fixture 的 metrics 结构必须稳定'
    Assert-True ('host wrapper deployment' -cin @($report.unverified) -and
        'live policy activation' -cin @($report.unverified) -and
        'real capability target deletion' -cin @($report.unverified) -and
        '16 GiB dataset' -cin @($report.unverified)) `
        '未执行的 host-live 与大规模 benchmark 必须明确标为未验证'

    [pscustomobject][ordered]@{
        ok = $true
        suite = 'CodexSafeTreeDeleteMetricsEvidence'
        datasets = 2
        stagesPerDataset = 9
    }
} finally {
    if ([IO.File]::Exists($outputPath)) { [IO.File]::Delete($outputPath) }
    Remove-TestEvidenceTree -Path $retainedEvidenceRoot
}
