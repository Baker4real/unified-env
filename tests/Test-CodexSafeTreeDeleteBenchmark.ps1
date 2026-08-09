[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$benchmarkPath = Join-Path $projectRoot 'scripts\Measure-CodexSafeTreeDelete.ps1'
$hostSafetyLibraryPath = Join-Path $projectRoot 'scripts\lib\CodexHostSafety.ps1'
$outputPath = Join-Path $projectRoot ("reports\safe-tree-delete-benchmark-test-{0}.json" -f [guid]::NewGuid().ToString('N'))
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
        -Name 'safe-delete benchmark retained evidence cleanup snapshot'
    Remove-CodexHookCapabilityDirectoryTree `
        -Path $Path `
        -CapabilityRoot (Split-Path -Parent $Path) `
        -AllowedExactPaths @($Path) `
        -ExpectedRootIdentity @($snapshot.rootIdentity) `
        -ExpectedTreeManifest $snapshot `
        -Scope 'safe-delete benchmark retained evidence cleanup'
}

try {
    & $benchmarkPath `
        -OutputPath $outputPath `
        -SmallDatasetBytes 1024 `
        -LargeDatasetBytes 1048576
    Assert-True ([IO.File]::Exists($outputPath)) 'benchmark 必须发布机器可读 evidence'
    $report = Get-Content -Raw -LiteralPath $outputPath |
        ConvertFrom-Json -Depth 128 -DateKind String -ErrorAction Stop
    Assert-True ($report.artifactType -ceq 'env-governance.codex-safe-tree-delete-benchmark') `
        'benchmark artifactType 必须稳定'
    Assert-True ($report.schemaVersion -eq 2) 'benchmark schemaVersion 必须稳定'
    Assert-True ($report.execution.exitCode -eq 0) '成功 benchmark 必须记录 exit code 0'
    Assert-True ($report.execution.exitStatus -ceq 'succeeded') `
        'benchmark 必须从实际执行结果记录成功状态'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$report.capturedAtUtc)) `
        'benchmark 必须记录 capturedAtUtc'
    Assert-True ($report.machine.processorCount -gt 0 -and
        [string]$report.machine.osArchitecture -cin @('X64', 'Arm64', 'X86', 'Arm') -and
        -not [string]::IsNullOrWhiteSpace([string]$report.machine.processArchitecture)) `
        'benchmark 必须记录可复核的机器与进程架构状态'
    Assert-True ($report.artifacts.sourceLibrarySha256 -match '^[0-9a-f]{64}$') `
        'benchmark 必须记录 source library SHA-256'
    Assert-True ($report.artifacts.sourceHostAdapterSha256 -match '^[0-9a-f]{64}$') `
        'benchmark 必须记录 source host adapter SHA-256'
    if ([string]$report.artifacts.liveWrapperStatus -ceq 'matched-source') {
        Assert-True (
            [string]$report.artifacts.liveWrapperSha256 -ceq
                [string]$report.artifacts.sourceHostAdapterSha256) `
            'matched-source 必须比较同职责的 source/live host adapter'
    }
    Assert-True ($report.artifacts.liveWrapperStatus -cin @('matched-source', 'different-from-source', 'not-checked')) `
        'benchmark 必须明确 live wrapper 验证状态'
    Assert-True ([string]$report.retainedEvidence.path -ceq $retainedEvidencePath) `
        'benchmark 必须引用 output 相邻的固定 retained evidence'
    Assert-True ($report.retainedEvidence.sha256 -match '^[0-9a-f]{64}$') `
        'benchmark 必须绑定 retained evidence SHA-256'
    Assert-True ($report.retainedEvidence.payloadBytesRetained -eq $false) `
        'retained evidence 不得包含 payload bytes'
    Assert-True ([IO.File]::Exists($retainedEvidencePath)) `
        'benchmark 必须保留独立可审计的阶段 evidence'
    Assert-True (
        ((Get-FileHash -LiteralPath $retainedEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq
            [string]$report.retainedEvidence.sha256)) `
        'report 必须精确绑定 retained evidence bytes'
    $evidence = Get-Content -Raw -LiteralPath $retainedEvidencePath |
        ConvertFrom-Json -Depth 128 -DateKind String -ErrorAction Stop
    Assert-True ($evidence.artifactType -ceq 'env-governance.codex-safe-tree-delete-benchmark-evidence') `
        'retained evidence artifactType 必须稳定'
    Assert-True ($evidence.schemaVersion -eq 1) 'retained evidence schemaVersion 必须稳定'
    Assert-True ($evidence.payloadBytesRetained -eq $false) `
        'retained evidence 必须明确未保留 payload bytes'
    Assert-True (@($report.datasets).Count -eq 2) 'benchmark 必须包含 small 与 large 数据集'
    Assert-True (@($evidence.datasets).Count -eq 2) `
        'retained evidence 必须包含 small 与 large 数据集'
    foreach ($dataset in @($report.datasets)) {
        Assert-True ($dataset.plan.metrics.phase -ceq 'plan') 'dataset 必须记录 Plan metrics'
        Assert-True ($dataset.status.metrics.phase -ceq 'status') 'dataset 必须记录 Status metrics'
        Assert-True ($dataset.apply.metrics.phase -ceq 'apply') 'dataset 必须记录 Apply metrics'
        Assert-True ($dataset.restore.metrics.phase -ceq 'restore') 'dataset 必须记录 Restore metrics'
        Assert-True ($dataset.purge.metrics.phase -ceq 'purge') 'dataset 必须记录 Purge metrics'
        Assert-True ($dataset.purge.deletionOutcome.physicalReclaimStatus -ceq 'unknown') `
            'benchmark 不得从 logical deletion 推断 physical reclaim'
        Assert-True ($dataset.fixture.directoryCount -ge 3) `
            '每个 benchmark 数据集必须包含多个目录'
        Assert-True ($dataset.fixture.fileCount -ge 4) `
            '每个 benchmark 数据集必须包含多个文件'
        Assert-True ($dataset.fixture.logicalBytes -eq $dataset.payloadBytes) `
            'benchmark fixture logical bytes 必须与输入精确一致'
        foreach ($phase in @('plan', 'status', 'apply', 'purge')) {
            Assert-True ($dataset.$phase.metrics.logicalBytes -eq $dataset.payloadBytes) `
                "$phase logical bytes 必须与 dataset 输入精确一致"
            Assert-True ($dataset.$phase.metrics.bytesHashed -ge $dataset.payloadBytes) `
                "$phase bytes hashed 必须独立记录实际认证读取"
        }
        Assert-True ($dataset.restore.metrics.phase -ceq 'restore' -and
            $dataset.restore.metrics.bytesHashed -ge $dataset.payloadBytes) `
            'Restore 必须记录统一 metrics 与实际认证读取'
        Assert-True ($dataset.purge.deletionOutcome.namespaceAbsent -eq $true -and
            $dataset.purge.deletionOutcome.logicalCompletion -eq $true -and
            $dataset.purge.deletionOutcome.physicalReclaimStatus -ceq 'unknown') `
            'benchmark 必须分离 namespace、logical completion 与 physical reclaim'
        Assert-True ($dataset.retainedEvidence.datasetName -ceq $dataset.name) `
            'dataset 必须引用 retained evidence 中的同名记录'
        Assert-True ($dataset.retainedEvidence.path -ceq $retainedEvidencePath) `
            'dataset evidence pointer 必须引用固定 retained evidence'

        $evidenceDataset = @($evidence.datasets | Where-Object name -CEQ $dataset.name)
        Assert-True ($evidenceDataset.Count -eq 1) 'retained evidence dataset 必须唯一'
        Assert-True ($evidenceDataset[0].fixture.directoryCount -ge 3) `
            'raw evidence 必须记录多目录 fixture 形状'
        Assert-True ($evidenceDataset[0].fixture.fileCount -ge 4) `
            'raw evidence 必须记录多文件 fixture 形状'
        $requiredStages = @(
            'plan', 'status-planned', 'apply', 'status-recoverable', 'restore',
            'purge-plan', 'purge-apply', 'purge', 'status-terminal')
        foreach ($stageName in $requiredStages) {
            $stage = @($evidenceDataset[0].stages | Where-Object name -CEQ $stageName)
            Assert-True ($stage.Count -eq 1) "retained evidence 必须包含唯一阶段：$stageName"
            Assert-True ($stage[0].invocation.scriptPath -ceq
                (Join-Path $projectRoot 'tests\Invoke-CodexSafeTreeDeleteFixture.ps1')) `
                "阶段必须记录实际 public script seam：$stageName"
            Assert-True (@($stage[0].invocation.parameters.PSObject.Properties).Count -gt 0) `
                "阶段必须记录 exact invocation inputs：$stageName"
            Assert-True ($stage[0].exitStatus -ceq 'succeeded' -and $stage[0].exitCode -eq 0) `
                "阶段必须记录实际成功结果：$stageName"
            Assert-True (-not [string]::IsNullOrWhiteSpace([string]$stage[0].startedAtUtc) -and
                -not [string]::IsNullOrWhiteSpace([string]$stage[0].completedAtUtc)) `
                "阶段必须记录可审计时间边界：$stageName"
            Assert-True ($null -ne $stage[0].result) "阶段必须保留完整结果：$stageName"
        }
    }
    Assert-True ($report.conclusion.hashReuseDesignRecommendation -ceq 'insufficient-evidence') `
        'fixture benchmark 不得直接建议降低内容认证合同'
    Assert-True ($report.conclusion.hashReuseDesignDecision -ceq
        'do-not-open-with-current-evidence') `
        'fixture benchmark 必须明确当前证据不足以另开 hash-reuse 设计'

    [pscustomobject][ordered]@{ ok = $true; suite = 'CodexSafeTreeDeleteBenchmark'; datasets = 2 }
} finally {
    if ([IO.File]::Exists($outputPath)) { [IO.File]::Delete($outputPath) }
    Remove-TestEvidenceTree -Path $retainedEvidenceRoot
}
