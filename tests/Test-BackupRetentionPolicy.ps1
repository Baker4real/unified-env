$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-CanRemoveBackupRetentionPolicyTestRoot {
    param([Parameter(Mandatory)][string]$Path)

    Assert-True ([IO.Path]::IsPathFullyQualified($Path)) '测试删除根必须是绝对路径'
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    Assert-True ([IO.Path]::GetPathRoot($fullPath) -ieq 'D:\') '测试删除根必须位于 D 盘'
    $reportsRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot 'reports')).TrimEnd('\', '/')
    Assert-True ($fullPath.StartsWith("$reportsRoot\", [StringComparison]::OrdinalIgnoreCase)) '测试删除根必须位于项目 reports fixture 子树'

    $driveRoot = [IO.Path]::GetPathRoot($fullPath)
    $current = $fullPath
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            Assert-True (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "测试删除根父链不得穿过 reparse point：$current"
        }
        if ($current.TrimEnd('\', '/') -ieq $driveRoot.TrimEnd('\', '/')) { break }
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent) { break }
        $next = $parent.FullName
        Assert-True ($next.TrimEnd('\', '/') -ine $current.TrimEnd('\', '/')) "测试删除根父链不得死循环：$current"
        $current = $next
    }
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$libraryPath = Join-Path $projectRoot 'scripts\lib\BackupRetentionPolicy.ps1'
$testRoot = Join-Path $projectRoot 'reports\backup-retention-policy-test'
$gsdJunction = Join-Path $testRoot '.gsd'
$skillsJunction = Join-Path $testRoot '.codex\skills'

if (Test-Path -LiteralPath $testRoot) {
    Assert-CanRemoveBackupRetentionPolicyTestRoot -Path $testRoot
    if (Test-Path -LiteralPath $gsdJunction) {
        $staleGsd = Get-Item -LiteralPath $gsdJunction -Force
        if (($staleGsd.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Remove-Item -LiteralPath $gsdJunction -Force }
    }
    if (Test-Path -LiteralPath $skillsJunction) {
        $staleSkills = Get-Item -LiteralPath $skillsJunction -Force
        if (($staleSkills.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Remove-Item -LiteralPath $skillsJunction -Force }
    }
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

    $backupsStateRoot = Join-Path $fixtureCodexRoot 'backups_state'
    $validSidecar = Join-Path $backupsStateRoot 'config.toml-20260701T010101Z'
    Set-Content -LiteralPath $validSidecar -Value 'valid sidecar' -Encoding UTF8
    $sidecarViolations = @(
        (Join-Path $backupsStateRoot '.codex-global-state.json-20260701T010102Z'),
        (Join-Path $backupsStateRoot 'config.tomlx-20260701T010103Z'),
        (Join-Path $backupsStateRoot 'config.toml-20260701T010104Z-junk'),
        (Join-Path $backupsStateRoot 'junk-config.toml-20260701T010105Z'),
        (Join-Path $backupsStateRoot 'config.toml_20260701T010106Z')
    )
    New-Item -ItemType Directory -Path $sidecarViolations[0] | Out-Null
    foreach ($path in $sidecarViolations[1..4]) { Set-Content -LiteralPath $path -Value 'invalid sidecar' -Encoding UTF8 }

    $junctionTarget = Join-Path $testRoot 'gsd-junction-target'
    $junctionReplicator = Join-Path $junctionTarget 'backups\replicator'
    New-Item -ItemType Directory -Force -Path $junctionReplicator | Out-Null
    foreach ($name in @('phase1-20260701T000006Z','phase1-20260701T000005Z','phase1-20260701T000004Z','phase1-20260701T000003Z','phase1-20260701T000002Z','phase1-20260701T000001Z')) {
        New-Item -ItemType Directory -Path (Join-Path $junctionReplicator $name) | Out-Null
    }
    New-Item -ItemType Junction -Path $gsdJunction -Target $junctionTarget | Out-Null
    $skillsTarget = Join-Path $testRoot 'skills-junction-target'
    New-Item -ItemType Directory -Force -Path $skillsTarget | Out-Null
    New-Item -ItemType Junction -Path $skillsJunction -Target $skillsTarget | Out-Null

    $context = New-BackupRetentionPolicyContext `
        -ArtifactMode test `
        -CodexRoot $fixtureCodexRoot `
        -DDriveRoot $testRoot `
        -RetainCount 5
    Assert-True ($context.artifactMode -ceq 'test') 'fixture context 必须显式标记为 test'

    $upperTestContext = New-BackupRetentionPolicyContext -ArtifactMode TEST -CodexRoot $fixtureCodexRoot -DDriveRoot $testRoot
    Assert-True ($upperTestContext.artifactMode -ceq 'test') 'ArtifactMode TEST 必须规范化为 test'
    $upperProductionRejected = $false
    try { New-BackupRetentionPolicyContext -ArtifactMode Production -CodexRoot $fixtureCodexRoot -DDriveRoot $testRoot | Out-Null } catch { $upperProductionRejected = $true }
    Assert-True $upperProductionRejected 'ArtifactMode Production 不得绕过 production 固定常量门'

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

    $validSidecarItem = @($evaluation.coverageItems | Where-Object path -ieq $validSidecar)
    Assert-True ($validSidecarItem.Count -eq 1 -and $validSidecarItem[0].itemType -ceq 'file' -and $validSidecarItem[0].coverageDisposition -ceq 'retained') '精确命名的 sidecar 文件应进入 retained'
    foreach ($invalidSidecar in $sidecarViolations) {
        $item = @($evaluation.coverageItems | Where-Object path -ieq $invalidSidecar)
        Assert-True ($item.Count -eq 1 -and $item[0].coverageDisposition -ceq 'gap' -and $item[0].requiresManualReview -and $item[0].blocksCoverage) "sidecar 目录/近似名/垃圾前后缀必须 gap：$invalidSidecar"
    }

    $gsdRoot = Join-Path $testRoot '.gsd\backups\replicator'
    $gsdRootState = @($evaluation.evaluatedRoots | Where-Object path -ieq $gsdRoot)[0]
    Assert-True (-not $gsdRootState.enumerationCompleted) '扫描根中间父级 .gsd 为 junction 时不得枚举'
    Assert-True (@($evaluation.coverageItems | Where-Object { $_.path -ieq $gsdRoot -and $_.coverageOrigin -ceq 'scan-root-error' -and $_.blocksCoverage }).Count -eq 1) '中间 junction 必须 root gap+manual+blocks'
    Assert-True (@($evaluation.candidates | Where-Object scanRoot -ieq $gsdRoot).Count -eq 0) '中间 junction 扫描根必须 0 candidate'

    $protectedReparse = @($evaluation.protected | Where-Object path -ieq $skillsJunction)[0]
    Assert-True ($protectedReparse.metadataStatus -ceq 'reparse' -and $protectedReparse.isReparsePoint -and $protectedReparse.reparseAncestor -ieq $skillsJunction -and -not [string]::IsNullOrWhiteSpace([string]$protectedReparse.reparseTarget)) 'protected reparse 必须投影 canonical metadata'
    Assert-True ($protectedReparse.requiresManualReview -and $protectedReparse.risk -ceq '高' -and $protectedReparse.blocksCoverage -and @($protectedReparse.errors).Count -gt 0 -and $protectedReparse.stats.reparsePointsSkipped -eq 1) 'protected reparse 必须 manual+高风险+blocks+errors，且与 stats 一致'

    $rootSnapshots = @($evaluation.evaluatedRoots)
    foreach ($root in $rootSnapshots) {
        Assert-True ($null -ne $root.enumerationStarted) '根快照必须记录 enumerationStarted'
        Assert-True ($null -ne $root.enumerationCompleted) '根快照必须记录 enumerationCompleted'
        Assert-True ($root.errors -is [array]) '根快照 errors 必须是数组'
        Assert-True ($root.snapshotSha256 -match '^[0-9a-f]{64}$') '根快照必须有 SHA-256'
        Assert-True ($root.classificationCount -eq $root.directChildCount) '每个根的分类数必须与直接子项数守恒'
        foreach ($property in @('metadataStatus','exists','rootIsReparsePoint','reparseAncestor','reparseTarget','enumerationStarted','enumerationCompleted','errors','directChildCount','directChildren','snapshotSha256','classificationCount','classificationCounts')) {
            Assert-True ($root.PSObject.Properties.Name -contains $property) "Task6 现场比较所需的 root state 缺少字段：$property"
        }
    }

    $missingRoot = @($rootSnapshots | Where-Object rootId -ceq 'archive-replicator')[0]
    Assert-True (-not $missingRoot.exists -and $missingRoot.enumerationCompleted -and $missingRoot.directChildCount -eq 0 -and @($missingRoot.errors).Count -eq 0) '缺失的声明根必须 exists=false、completed=true、0 items、0 errors'
    Assert-True (@($evaluation.coverageItems | Where-Object { $_.path -ieq $missingRoot.path -and $_.coverageOrigin -ceq 'scan-root-error' }).Count -eq 0) '缺失声明根本身不阻塞覆盖'

    $emptyScopeRoot = Join-Path $testRoot 'empty-scope'
    $emptyContext = New-BackupRetentionPolicyContext -ArtifactMode test -CodexRoot (Join-Path $emptyScopeRoot '.codex') -DDriveRoot $emptyScopeRoot
    $emptyEvaluation = Invoke-BackupRetentionEvaluation -PolicyContext $emptyContext
    Assert-True ($emptyEvaluation.coverageAccounted -and $emptyEvaluation.coverageComplete -and @($emptyEvaluation.unclassifiedCoverageGaps).Count -eq 0) '全部声明根缺失时应视为空集合已完成，不阻塞覆盖'

    $retained = @($evaluation.retainedItems | Where-Object { $_.scanRoot -ieq $providerRoot })
    $candidate = @($evaluation.candidates | Where-Object { $_.scanRoot -ieq $providerRoot })
    Assert-True ($retained.Count -eq 5) '最新 5 个 provider-sync 必须为 retained'
    Assert-True ($candidate.Count -eq 1) '第 6 个 provider-sync 必须为 candidate'

    $lateScopeRoot = Join-Path $testRoot 'late-scope'
    $lateProviderRoot = Join-Path $lateScopeRoot '.codex\backups_state\provider-sync'
    New-Item -ItemType Directory -Force -Path $lateProviderRoot | Out-Null
    foreach ($name in @('20260701T000006Z','20260701T000005Z','20260701T000004Z','20260701T000003Z','20260701T000002Z','20260701T000001Z')) {
        New-Item -ItemType Directory -Path (Join-Path $lateProviderRoot $name) | Out-Null
    }
    $lateContext = New-BackupRetentionPolicyContext -ArtifactMode test -CodexRoot (Join-Path $lateScopeRoot '.codex') -DDriveRoot $lateScopeRoot
    $script:LateCandidatePath = Join-Path $lateProviderRoot '20260701T000001Z'
    $lateReparseResolver = {
        param([string]$Path, [string]$TrustedRoot)
        if ($Path -ieq $script:LateCandidatePath) {
            return [pscustomobject]@{ status = 'reparse'; error = $null; exists = $true; isReparsePoint = $true; reparseAncestor = (Split-Path -Parent $Path); reparseTarget = 'D:\Elsewhere' }
        }
        Get-BackupRetentionPathChainState -Path $Path -TrustedRoot $TrustedRoot
    }
    $lateEvaluation = Invoke-BackupRetentionEvaluation -PolicyContext $lateContext -PathChainResolver $lateReparseResolver
    $lateProviderState = @($lateEvaluation.evaluatedRoots | Where-Object path -ieq $lateProviderRoot)[0]
    Assert-True ($lateProviderState.enumerationCompleted -and $lateProviderState.directChildCount -eq 6) 'late resolver 不得让 providerRoot snapshot 失败'
    Assert-True (@($lateEvaluation.evaluatedRoots | Where-Object { $_.path -ine $lateProviderRoot -and -not $_.enumerationCompleted }).Count -eq 0) 'late resolver 的非目标 roots 必须全部成功'
    Assert-True (@($lateEvaluation.coverageItems | Where-Object scanRoot -ieq $lateProviderRoot).Count -eq 6) 'providerRoot 必须保留恰好 6 个 coverageItems'
    Assert-True (@($lateEvaluation.candidates).Count -eq 0 -and @($lateEvaluation.retainedItems | Where-Object scanRoot -ieq $lateProviderRoot).Count -eq 5) '应只把最旧 candidate 降级，其余 5 项保留'
    Assert-True (@($lateEvaluation.coverageItems | Where-Object { $_.path -ieq $script:LateCandidatePath -and $_.coverageDisposition -ceq 'gap' -and $_.blocksCoverage }).Count -eq 1 -and -not $lateEvaluation.coverageComplete) '候选祖先 junction 必须成为唯一目标 gap 并令 coverageComplete=false'
    Assert-True (@($lateEvaluation.coverageItems | Where-Object coverageDisposition -ceq 'gap').Count -eq 1) 'late evaluation 中必须恰好只有目标旧 candidate 一个 gap'

    $metadataFailureResolver = {
        param([string]$Path, [string]$TrustedRoot)
        if ($Path -ieq $script:LateCandidatePath) { return [pscustomobject]@{ status = 'error'; error = 'fixture metadata failure'; exists = $true; isReparsePoint = $null; reparseAncestor = $null; reparseTarget = $null } }
        Get-BackupRetentionPathChainState -Path $Path -TrustedRoot $TrustedRoot
    }
    $metadataFailureEvaluation = Invoke-BackupRetentionEvaluation -PolicyContext $lateContext -PathChainResolver $metadataFailureResolver
    Assert-True (@($metadataFailureEvaluation.candidates | Where-Object path -ieq $script:LateCandidatePath).Count -eq 0) '候选路径 reparse metadata 失败必须失败关闭'

    $invalidMetadataResolver = {
        param([string]$Path, [string]$TrustedRoot)
        if ($Path -ieq $script:LateCandidatePath) { return [pscustomobject]@{ status = 'ok'; error = $null; exists = 'false'; isReparsePoint = $false; reparseAncestor = $null; reparseTarget = $null } }
        Get-BackupRetentionPathChainState -Path $Path -TrustedRoot $TrustedRoot
    }
    $invalidMetadataEvaluation = Invoke-BackupRetentionEvaluation -PolicyContext $lateContext -PathChainResolver $invalidMetadataResolver
    Assert-True (@($invalidMetadataEvaluation.candidates | Where-Object path -ieq $script:LateCandidatePath).Count -eq 0) '候选路径 metadata 宽松类型不得绕过 fail-closed 门'

    $rootMetadataFailureResolver = {
        param([string]$Path, [string]$TrustedRoot)
        if ($Path -ieq $lateProviderRoot) { return [pscustomobject]@{ status = 'error'; error = 'fixture root metadata failure'; exists = $null; isReparsePoint = $null; reparseAncestor = $null; reparseTarget = $null } }
        Get-BackupRetentionPathChainState -Path $Path -TrustedRoot $TrustedRoot
    }
    $rootMetadataFailureEvaluation = Invoke-BackupRetentionEvaluation -PolicyContext $lateContext -PathChainResolver $rootMetadataFailureResolver
    $failedProviderRoot = @($rootMetadataFailureEvaluation.evaluatedRoots | Where-Object path -ieq $lateProviderRoot)[0]
    Assert-True ($failedProviderRoot.metadataStatus -ceq 'error' -and -not $failedProviderRoot.enumerationCompleted -and $null -eq $failedProviderRoot.exists) '声明根 reparse metadata 失败时必须保留 unknown exists 并停止枚举'
    Assert-True (@($rootMetadataFailureEvaluation.candidates | Where-Object scanRoot -ieq $lateProviderRoot).Count -eq 0) '声明根 metadata 失败后必须 0 candidate'

    $script:GuardrailErrorPath = Join-Path $fixtureCodexRoot 'plugins\cache'
    $script:GuardrailNullPath = Join-Path $fixtureCodexRoot 'account_backup'
    $guardrailFailureResolver = {
        param([string]$Path, [string]$TrustedRoot)
        if ($Path -ieq $script:GuardrailErrorPath) { return [pscustomobject]@{ status = 'error'; error = 'fixture protected metadata failure'; exists = $null; isReparsePoint = $null; reparseAncestor = $null; reparseTarget = $null } }
        if ($Path -ieq $script:GuardrailNullPath) { return $null }
        Get-BackupRetentionPathChainState -Path $Path -TrustedRoot $TrustedRoot
    }
    $guardrailFailureEvaluation = Invoke-BackupRetentionEvaluation -PolicyContext $context -PathChainResolver $guardrailFailureResolver
    foreach ($guardrailPath in @($script:GuardrailErrorPath, $script:GuardrailNullPath)) {
        $protectedFailure = @($guardrailFailureEvaluation.protected | Where-Object path -ieq $guardrailPath)[0]
        Assert-True ($protectedFailure.metadataStatus -ceq 'error' -and $null -eq $protectedFailure.isReparsePoint -and $null -eq $protectedFailure.reparseAncestor -and $null -eq $protectedFailure.reparseTarget -and @($protectedFailure.errors).Count -gt 0) "protected metadata error/null 必须 canonical 投影：$guardrailPath"
        Assert-True ($protectedFailure.requiresManualReview -and $protectedFailure.risk -ceq '高' -and $protectedFailure.blocksCoverage -and $protectedFailure.stats.inaccessibleItems -eq 1) "protected metadata error/null 必须 manual+高风险+blocks，且与 stats 一致：$guardrailPath"
    }

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
        Assert-CanRemoveBackupRetentionPolicyTestRoot -Path $testRoot
        if (Test-Path -LiteralPath $gsdJunction) {
            $gsdItem = Get-Item -LiteralPath $gsdJunction -Force
            if (($gsdItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Remove-Item -LiteralPath $gsdJunction -Force }
        }
        if (Test-Path -LiteralPath $skillsJunction) {
            $skillsItem = Get-Item -LiteralPath $skillsJunction -Force
            if (($skillsItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Remove-Item -LiteralPath $skillsJunction -Force }
        }
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

[pscustomobject]@{ ok = $true }
