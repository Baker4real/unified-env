$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$libraryPath = Join-Path $projectRoot 'scripts\lib\BackupRetentionPolicy.ps1'
$testRoot = Join-Path $projectRoot 'reports\backup-retention-policy-test'

if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}

try {
    . $libraryPath

    $fixtureCodexRoot = Join-Path $testRoot '.codex'
    $providerRoot = Join-Path $fixtureCodexRoot 'backups_state\provider-sync'
    New-Item -ItemType Directory -Force -Path $providerRoot | Out-Null
    foreach ($name in @(
        '20260701T000007Z', '20260701T000006Z', '20260701T000005Z',
        '20260701T000004Z', '20260701T000003Z', '20260701T000002Z'
    )) {
        New-Item -ItemType Directory -Path (Join-Path $providerRoot $name) | Out-Null
    }
    New-Item -ItemType Directory -Path (Join-Path $providerRoot 'unknown-directory') | Out-Null
    Set-Content -LiteralPath (Join-Path $providerRoot 'unknown-file.bin') -Value 'unknown' -Encoding UTF8
    $hiddenPath = Join-Path $providerRoot 'hidden-unknown.bin'
    Set-Content -LiteralPath $hiddenPath -Value 'hidden unknown' -Encoding UTF8
    (Get-Item -LiteralPath $hiddenPath -Force).Attributes = (Get-Item -LiteralPath $hiddenPath -Force).Attributes -bor [IO.FileAttributes]::Hidden
    $nonDirectoryScanRoot = Join-Path $testRoot 'apps\codex_switch\backups'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $nonDirectoryScanRoot) | Out-Null
    Set-Content -LiteralPath $nonDirectoryScanRoot -Value 'not a directory' -Encoding UTF8

    $context = New-BackupRetentionPolicyContext `
        -ArtifactMode test `
        -CodexRoot $fixtureCodexRoot `
        -DDriveRoot $testRoot `
        -RetainCount 5
    Assert-True ($context.artifactMode -ceq 'test') 'fixture context 必须显式标记为 test'

    $evaluation = Invoke-BackupRetentionEvaluation -PolicyContext $context
    $unknownDirectory = @($evaluation.coverageItems | Where-Object { $_.path -ieq (Join-Path $providerRoot 'unknown-directory') })
    $unknownFile = @($evaluation.coverageItems | Where-Object { $_.path -ieq (Join-Path $providerRoot 'unknown-file.bin') })
    foreach ($items in @($unknownDirectory, $unknownFile)) {
        Assert-True ($items.Count -eq 1) '未知直接子项必须恰好记录一次'
        Assert-True ($items[0].coverageDisposition -ceq 'gap') '未知文件/目录必须进入 gap'
        Assert-True $items[0].blocksCoverage '未知项必须阻塞覆盖完整性'
        Assert-True $items[0].coverageAccounted '未知项仍必须计入覆盖账本'
        Assert-True $items[0].requiresManualReview '未知项必须人工审查'
    }
    Assert-True $evaluation.coverageAccounted '已枚举子项必须计数守恒'
    Assert-True (-not $evaluation.coverageComplete) '存在 gap 时 coverageComplete 必须为 false'
    Assert-True (@($evaluation.unclassifiedCoverageGaps | Where-Object { $_.scanRoot -ieq $providerRoot }).Count -eq 3) '未知文件、目录和隐藏文件都必须投影到 gap 列表'
    Assert-True (@($evaluation.coverageItems | Where-Object { $_.path -ieq $hiddenPath }).Count -eq 1) 'Get-ChildItem -Force 必须覆盖隐藏子项'
    $rootFailure = @($evaluation.coverageItems | Where-Object { $_.path -ieq $nonDirectoryScanRoot -and $_.coverageOrigin -ceq 'scan-root-error' })
    Assert-True ($rootFailure.Count -eq 1 -and $rootFailure[0].blocksCoverage -and $rootFailure[0].requiresManualReview) '声明扫描根被文件占用时必须 gap+manual+blocks'

    $rootSnapshots = @($evaluation.evaluatedRoots)
    foreach ($root in $rootSnapshots) {
        Assert-True ($null -ne $root.enumerationStarted) '根快照必须记录 enumerationStarted'
        Assert-True ($null -ne $root.enumerationCompleted) '根快照必须记录 enumerationCompleted'
        Assert-True ($root.errors -is [array]) '根快照 errors 必须是数组'
        Assert-True ($root.snapshotSha256 -match '^[0-9a-f]{64}$') '根快照必须有 SHA-256'
        Assert-True ($root.classificationCount -eq $root.directChildCount) '每个根的分类数必须与直接子项数守恒'
    }

    $retained = @($evaluation.retainedItems | Where-Object { $_.scanRoot -ieq $providerRoot })
    $candidate = @($evaluation.candidates | Where-Object { $_.scanRoot -ieq $providerRoot })
    Assert-True ($retained.Count -eq 5) '最新 5 个 provider-sync 必须为 retained'
    Assert-True ($candidate.Count -eq 1) '第 6 个 provider-sync 必须为 candidate'

    $parentRoot = Join-Path $fixtureCodexRoot 'backups_state'
    $delegated = @($evaluation.coverageItems | Where-Object {
        $_.scanRoot -ieq $parentRoot -and $_.path -ieq $providerRoot
    })
    Assert-True ($delegated.Count -eq 1) 'provider-sync 在父根中必须恰好出现一次'
    Assert-True ($delegated[0].coverageDisposition -ceq 'delegated-root') 'provider-sync 在父根中必须是 delegated-root'
    Assert-True ($delegated[0].delegatedScanRoot -ieq $providerRoot) '委托目标必须等于子项规范路径'

    $validRoots = @(
        [pscustomobject]@{ path = $parentRoot; exists = $true; enumerationCompleted = $true },
        [pscustomobject]@{ path = $providerRoot; exists = $true; enumerationCompleted = $true }
    )
    $validDelegation = @([pscustomobject]@{
        scanRoot = $parentRoot
        path = $providerRoot
        coverageDisposition = 'delegated-root'
        delegatedScanRoot = $providerRoot
    })
    Assert-True ((Test-BackupRetentionDelegationGraph -DeclaredScanRoots $validRoots -CoverageItems $validDelegation).valid) '合法直接子根委托应通过'

    $self = @([pscustomobject]@{ scanRoot = $parentRoot; path = $parentRoot; coverageDisposition = 'delegated-root'; delegatedScanRoot = $parentRoot })
    Assert-True (-not (Test-BackupRetentionDelegationGraph -DeclaredScanRoots $validRoots -CoverageItems $self).valid) '自引用委托必须失败关闭'

    $cycle = @(
        [pscustomobject]@{ scanRoot = $parentRoot; path = $providerRoot; coverageDisposition = 'delegated-root'; delegatedScanRoot = $providerRoot },
        [pscustomobject]@{ scanRoot = $providerRoot; path = $parentRoot; coverageDisposition = 'delegated-root'; delegatedScanRoot = $parentRoot }
    )
    Assert-True (-not (Test-BackupRetentionDelegationGraph -DeclaredScanRoots $validRoots -CoverageItems $cycle).valid) '双向环必须失败关闭'

    $deepTarget = Join-Path $providerRoot 'nested'
    $nonDirect = @([pscustomobject]@{ scanRoot = $parentRoot; path = $deepTarget; coverageDisposition = 'delegated-root'; delegatedScanRoot = $deepTarget })
    Assert-True (-not (Test-BackupRetentionDelegationGraph -DeclaredScanRoots @($validRoots + [pscustomobject]@{ path = $deepTarget; exists = $true; enumerationCompleted = $true }) -CoverageItems $nonDirect).valid) '非直接子项委托必须失败关闭'

    $otherParent = Join-Path $testRoot 'other-parent'
    $multiParent = @(
        [pscustomobject]@{ scanRoot = $parentRoot; path = $providerRoot; coverageDisposition = 'delegated-root'; delegatedScanRoot = $providerRoot },
        [pscustomobject]@{ scanRoot = $otherParent; path = $providerRoot; coverageDisposition = 'delegated-root'; delegatedScanRoot = $providerRoot }
    )
    $multiRoots = @($validRoots + [pscustomobject]@{ path = $otherParent; exists = $true; enumerationCompleted = $true })
    Assert-True (-not (Test-BackupRetentionDelegationGraph -DeclaredScanRoots $multiRoots -CoverageItems $multiParent).valid) '多父归属必须失败关闭'

    $productionRejected = $false
    try {
        New-BackupRetentionPolicyContext -ArtifactMode production -CodexRoot $fixtureCodexRoot -DDriveRoot $testRoot -RetainCount 5 | Out-Null
    } catch { $productionRejected = $true }
    Assert-True $productionRejected 'production context 必须精确匹配固定常量'

    $production = New-BackupRetentionPolicyContext
    Assert-True ($production.CodexRoot -ceq 'D:\Codex\.codex') 'production CodexRoot 必须固定'
    Assert-True ($production.DDriveRoot -ceq 'D:\Codex') 'production DDriveRoot 必须固定'
    Assert-True ($production.retainCount -eq 5) 'production retainCount 必须固定'
    Assert-True ($production.policyId -ceq 'env-governance.backup-retention') 'production policyId 必须固定'
    Assert-True ($production.policyVersion -eq 2) 'production policyVersion 必须固定'
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

[pscustomobject]@{ ok = $true }
