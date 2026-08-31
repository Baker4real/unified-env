$backupRetentionLibraryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $backupRetentionLibraryRoot 'lib\EnvPathSafety.ps1')

function Get-BackupRetentionCanonicalPath {
    param([Parameter(Mandatory)][string]$Path)

    Assert-EnvSafeAbsolutePath -Path $Path -FactName 'backup retention path'
    $fullPath = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($fullPath)
    if ($fullPath -ieq $root) { return $root }
    return $fullPath.TrimEnd('\', '/')
}

function Test-BackupRetentionReparseAncestor {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = Get-BackupRetentionCanonicalPath -Path $Path
    $trustedRoot = [IO.Path]::GetPathRoot($fullPath)
    $state = Get-BackupRetentionPathChainState -Path $fullPath -TrustedRoot $trustedRoot
    if ($state.status -ceq 'error') {
        throw "reparse metadata 读取失败：$($state.error)"
    }
    return [pscustomobject]@{
        ok = $state.status -ceq 'ok'
        firstReparsePoint = $state.reparseAncestor
    }
}

function Test-BackupRetentionPathWithinRoot {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)
    $fullPath = Get-BackupRetentionCanonicalPath -Path $Path
    $fullRoot = Get-BackupRetentionCanonicalPath -Path $Root
    return $fullPath -ieq $fullRoot -or $fullPath.StartsWith("$($fullRoot.TrimEnd('\'))\", [StringComparison]::OrdinalIgnoreCase)
}

function Get-BackupRetentionPathChainState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$TrustedRoot
    )

    $fullPath = Get-BackupRetentionCanonicalPath -Path $Path
    $fullTrustedRoot = Get-BackupRetentionCanonicalPath -Path $TrustedRoot
    if (-not (Test-BackupRetentionPathWithinRoot -Path $fullPath -Root $fullTrustedRoot)) {
        return [pscustomobject]@{ status = 'error'; error = "路径不在受信根内：$fullPath"; exists = $null; isReparsePoint = $null; reparseAncestor = $null; reparseTarget = $null }
    }

    $leafExists = $null
    $current = $fullPath
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        try {
            $exists = Test-Path -LiteralPath $current -ErrorAction Stop
            if ($current -ieq $fullPath) { $leafExists = [bool]$exists }
            if ($exists) {
                $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
                $isReparse = ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
                if ($isReparse) {
                    $target = $null
                    if ($item.PSObject.Properties.Name -contains 'Target') {
                        $targetValue = $item.Target
                        $target = if ($targetValue -is [array]) { @($targetValue) -join ';' } else { [string]$targetValue }
                    }
                    return [pscustomobject]@{ status = 'reparse'; error = $null; exists = $leafExists; isReparsePoint = $true; reparseAncestor = $current; reparseTarget = $target }
                }
            }
        } catch {
            return [pscustomobject]@{ status = 'error'; error = $_.Exception.Message; exists = $leafExists; isReparsePoint = $null; reparseAncestor = $null; reparseTarget = $null }
        }

        if ($current -ieq $fullTrustedRoot) {
            return [pscustomobject]@{ status = 'ok'; error = $null; exists = $leafExists; isReparsePoint = $false; reparseAncestor = $null; reparseTarget = $null }
        }
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent -or $parent.FullName.TrimEnd('\') -ieq $current.TrimEnd('\')) {
            return [pscustomobject]@{ status = 'error'; error = "未能到达受信根：$fullTrustedRoot"; exists = $leafExists; isReparsePoint = $null; reparseAncestor = $null; reparseTarget = $null }
        }
        $current = Get-BackupRetentionCanonicalPath -Path $parent.FullName
    }
    return [pscustomobject]@{ status = 'error'; error = "路径父链意外终止：$fullPath"; exists = $leafExists; isReparsePoint = $null; reparseAncestor = $null; reparseTarget = $null }
}

function Resolve-BackupRetentionPathChainState {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$TrustedRoot,
        [Parameter(Mandatory)][scriptblock]$PathChainResolver
    )
    try { $state = & $PathChainResolver $Path $TrustedRoot } catch {
        return [pscustomobject]@{ status = 'error'; error = $_.Exception.Message; exists = $null; isReparsePoint = $null; reparseAncestor = $null; reparseTarget = $null }
    }
    if ($null -eq $state) {
        return [pscustomobject]@{ status = 'error'; error = 'path chain resolver returned null'; exists = $null; isReparsePoint = $null; reparseAncestor = $null; reparseTarget = $null }
    }
    foreach ($field in @('status','exists','isReparsePoint','reparseAncestor','reparseTarget')) {
        if ($state.PSObject.Properties.Name -notcontains $field) {
            return [pscustomobject]@{ status = 'error'; error = "path chain metadata omitted $field"; exists = $null; isReparsePoint = $null; reparseAncestor = $null; reparseTarget = $null }
        }
    }
    if ($state.status -isnot [string] -or -not (@('ok','reparse','error') -ccontains $state.status) -or
        ($state.status -in @('ok','reparse') -and $state.exists -isnot [bool]) -or
        ($state.status -ceq 'ok' -and ($state.isReparsePoint -isnot [bool] -or $state.isReparsePoint -or $null -ne $state.reparseAncestor -or $null -ne $state.reparseTarget)) -or
        ($state.status -ceq 'reparse' -and ($state.isReparsePoint -isnot [bool] -or -not $state.isReparsePoint -or [string]::IsNullOrWhiteSpace([string]$state.reparseAncestor) -or ($null -ne $state.reparseTarget -and $state.reparseTarget -isnot [string]))) -or
        ($state.status -ceq 'error' -and [string]::IsNullOrWhiteSpace([string]$state.error))) {
        return [pscustomobject]@{ status = 'error'; error = 'invalid path chain metadata contract'; exists = $null; isReparsePoint = $null; reparseAncestor = $null; reparseTarget = $null }
    }
    if ($state.status -ceq 'reparse') {
        try {
            $ancestor = Get-BackupRetentionCanonicalPath -Path ([string]$state.reparseAncestor)
            if (-not (Test-BackupRetentionPathWithinRoot -Path $ancestor -Root $TrustedRoot) -or -not (Test-BackupRetentionPathWithinRoot -Path $Path -Root $ancestor)) { throw 'reparse ancestor is outside the trusted path chain' }
        } catch {
            return [pscustomobject]@{ status = 'error'; error = $_.Exception.Message; exists = $null; isReparsePoint = $null; reparseAncestor = $null; reparseTarget = $null }
        }
    }
    return $state
}

function Assert-BackupRetentionDPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    $fullPath = Get-BackupRetentionCanonicalPath -Path $Path
    if ([IO.Path]::GetPathRoot($fullPath) -ine 'D:\') {
        throw "$Name 必须位于 D:\ 下：$fullPath"
    }
    $reparse = Test-BackupRetentionReparseAncestor -Path $fullPath
    if (-not $reparse.ok) {
        throw "$Name 不得穿过 reparse point：$($reparse.firstReparsePoint)"
    }
    return $fullPath
}

function New-BackupRetentionPolicyContext {
    [CmdletBinding()]
    param(
        [ValidateSet('production', 'test')][string]$ArtifactMode = 'production',
        [string]$CodexRoot = 'D:\Codex\.codex',
        [string]$DDriveRoot = 'D:\Codex',
        [int]$RetainCount = 5
    )

    $canonicalArtifactMode = $ArtifactMode.ToLowerInvariant()
    $canonicalCodexRoot = Assert-BackupRetentionDPath -Path $CodexRoot -Name 'CodexRoot'
    $canonicalDDriveRoot = Assert-BackupRetentionDPath -Path $DDriveRoot -Name 'DDriveRoot'
    if ($RetainCount -lt 1) { throw 'RetainCount 必须大于等于 1。' }

    if ($canonicalArtifactMode -ceq 'production') {
        if ($canonicalCodexRoot -cne 'D:\Codex\.codex' -or
            $canonicalDDriveRoot -cne 'D:\Codex' -or
            $RetainCount -ne 5) {
            throw 'production context 必须精确使用 CodexRoot=D:\Codex\.codex、DDriveRoot=D:\Codex、retainCount=5。'
        }
    }

    return [pscustomobject][ordered]@{
        artifactMode = $canonicalArtifactMode
        CodexRoot = $canonicalCodexRoot
        DDriveRoot = $canonicalDDriveRoot
        retainCount = $RetainCount
        policyId = 'env-governance.backup-retention'
        policyVersion = 3
    }
}

function Get-BackupRetentionDeclaredScanRoots {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$PolicyContext)

    return @(
        [pscustomobject]@{ rootId = 'codex-backups-state'; path = Get-BackupRetentionCanonicalPath (Join-Path $PolicyContext.CodexRoot 'backups_state'); rule = 'backups-state-root' },
        [pscustomobject]@{ rootId = 'provider-sync'; path = Get-BackupRetentionCanonicalPath (Join-Path $PolicyContext.CodexRoot 'backups_state\provider-sync'); rule = 'provider-sync' },
        [pscustomobject]@{ rootId = 'codex-switch-installed-backups'; path = Get-BackupRetentionCanonicalPath (Join-Path $PolicyContext.DDriveRoot 'apps\codex_switch\backups'); rule = 'codex-switch' }
    )
}

function Get-BackupRetentionPolicyDocument {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$PolicyContext)
    if($PolicyContext.policyId-cne'env-governance.backup-retention'-or$PolicyContext.policyVersion-ne3){throw 'PolicyContext 不能生成 canonical policy document。'}
    return [pscustomobject][ordered]@{
        policyId=$PolicyContext.policyId
        policyVersion=$PolicyContext.policyVersion
        summary='只读 dry-run；不删除、不移动、不迁移；真实清理必须另行显式授权。'
        protectedRootsCannotBeDeleted=$true
        explicitAuthorizationRequired=$true
        applyMustRegenerateDryRun=$true
        applyMustCheckReparsePoints=$true
        applyMustUseAllowlist=$true
        strictTimestampRequired=$true
        runtimeSharedDirsExcluded=$true
        authAutosaveExcludedByDefault=$true
    }
}

function Get-BackupRetentionKnownBackupsStateManualDirectoryNames {
    return [string[]]@(
        'chrome-native-hosts-fix-20260701-230016',
        'codex-launcher-visibility',
        'codex-path-clean',
        'codex-state-policy',
        'github-cli-native-entry',
        'hermes-data-migration',
        'machine-path',
        'provider-stability-guard',
        'remote-plugin-debug-20260630',
        'serena-dashboard-guard',
        'sub2api'
    )
}

function Test-BackupRetentionManualStatsTrusted {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Item)

    if ($Item.pathExists -isnot [bool] -or -not $Item.pathExists -or $null -eq $Item.stats -or $Item.metadataStatus -cne 'ok' -or @($Item.errors).Count -ne 0) {
        return $false
    }

    $stats = $Item.stats
    foreach ($name in @('reparsePointsSkipped', 'inaccessibleItems')) {
        if ($stats.PSObject.Properties.Name -notcontains $name -or [int64]$stats.$name -ne 0) {
            return $false
        }
    }

    return $true
}

function Get-BackupRetentionEvaluationSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Evaluation)

    $candidates = @($Evaluation.candidates)
    $manualReview = @($Evaluation.manualReview)
    $manualExisting = @($manualReview | Where-Object { $_.pathExists -is [bool] -and $_.pathExists })
    $manualAbsent = @($manualReview | Where-Object { $_.pathExists -is [bool] -and -not $_.pathExists })
    $manualExistenceUnknown = @($manualReview | Where-Object { $_.pathExists -isnot [bool] })
    $manualWithStats = @($manualExisting | Where-Object { Test-BackupRetentionManualStatsTrusted -Item $_ })
    $manualWithoutStats = @($manualExisting | Where-Object { -not (Test-BackupRetentionManualStatsTrusted -Item $_) })
    $manualStatsUnknownCount = $manualWithoutStats.Count + $manualExistenceUnknown.Count
    $manualStatsComplete = $manualStatsUnknownCount -eq 0

    $candidateBytes = [int64](($candidates | ForEach-Object {
        if ($null -ne $_.stats) { [int64]$_.stats.bytes } else { 0 }
    } | Measure-Object -Sum).Sum)
    $manualReviewBytes = if ($manualStatsComplete) {
        [int64](($manualWithStats | ForEach-Object { [int64]$_.stats.bytes } | Measure-Object -Sum).Sum)
    } else {
        $null
    }

    return [pscustomobject][ordered]@{
        declaredScanRootCount = @($Evaluation.declaredScanRoots).Count
        evaluatedRootCount = @($Evaluation.evaluatedRoots).Count
        coverageItemCount = @($Evaluation.coverageItems).Count
        candidateCount = $candidates.Count
        retainedCount = @($Evaluation.retainedItems).Count
        protectedCount = @($Evaluation.protected).Count
        manualReviewCount = $manualReview.Count
        manualReviewExistingCount = $manualExisting.Count
        manualReviewAbsentCount = $manualAbsent.Count
        manualReviewExistenceUnknownCount = $manualExistenceUnknown.Count
        gapCount = @($Evaluation.unclassifiedCoverageGaps).Count
        candidateBytes = $candidateBytes
        candidateMb = [math]::Round($candidateBytes / 1MB, 2)
        manualReviewStatsKnownCount = $manualWithStats.Count
        manualReviewStatsUnknownCount = $manualStatsUnknownCount
        manualReviewStatsComplete = $manualStatsComplete
        manualReviewBytes = $manualReviewBytes
        manualReviewMb = if ($null -ne $manualReviewBytes) { [math]::Round($manualReviewBytes / 1MB, 2) } else { $null }
        candidateSkillMd = [int](($candidates | ForEach-Object {
            if ($null -ne $_.stats) { [int]$_.stats.skillMd } else { 0 }
        } | Measure-Object -Sum).Sum)
        selectedByRetentionCount = $candidates.Count
        lowRiskCount = @($candidates | Where-Object risk -eq '低').Count
        mediumRiskCount = @($candidates | Where-Object risk -eq '中').Count
        highRiskCount = @($candidates | Where-Object risk -eq '高').Count
        byBucket = [object[]]@($candidates | Group-Object bucket | ForEach-Object { [pscustomobject]@{ bucket = $_.Name; count = $_.Count } })
        manualByBucket = [object[]]@($manualReview | Group-Object bucket | ForEach-Object { [pscustomobject]@{ bucket = $_.Name; count = $_.Count } })
    }
}

function Get-BackupRetentionSha256 {
    param([Parameter(Mandatory)][string]$Value)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-BackupRetentionReparseMetadata {
    param([Parameter(Mandatory)][System.IO.FileSystemInfo]$Item)

    $isReparse = ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    $target = $null
    if ($isReparse -and $Item.PSObject.Properties.Name -contains 'Target') {
        $targetValue = $Item.Target
        if ($targetValue -is [array]) { $target = @($targetValue) -join ';' } else { $target = [string]$targetValue }
    }
    return [pscustomobject]@{ isReparsePoint = $isReparse; reparseTarget = $target }
}

function Get-BackupRetentionRootSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$DeclaredScanRoot,
        [string]$TrustedRoot = '',
        [scriptblock]$PathChainResolver = { param($Path, $Root) Get-BackupRetentionPathChainState -Path $Path -TrustedRoot $Root }
    )

    $path = Get-BackupRetentionCanonicalPath -Path ([string]$DeclaredScanRoot.path)
    $started = $true
    $errors = [Collections.Generic.List[string]]::new()
    $items = [Collections.Generic.List[object]]::new()
    $exists = $false
    $rootIsReparse = $false
    $reparseAncestor = $null
    $reparseTarget = $null
    $metadataStatus = 'error'
    $completed = $false

    try {
        if ([string]::IsNullOrWhiteSpace($TrustedRoot)) { $TrustedRoot = [IO.Path]::GetPathRoot($path) }
        $chain = Resolve-BackupRetentionPathChainState -Path $path -TrustedRoot $TrustedRoot -PathChainResolver $PathChainResolver
        $metadataStatus = [string]$chain.status
        $exists = if ($chain.exists -is [bool]) { [bool]$chain.exists } else { $null }
        if ($chain.status -ceq 'error') {
            $errors.Add("reparse metadata 读取失败：$($chain.error)")
        } elseif ($chain.status -ceq 'reparse') {
            $rootIsReparse = $true
            $reparseAncestor = [string]$chain.reparseAncestor
            $reparseTarget = $chain.reparseTarget
            $errors.Add("声明扫描根父链命中 reparse point：$reparseAncestor")
        }
        if ($chain.status -ceq 'ok' -and -not $exists) {
            $completed = $true
        } elseif ($chain.status -ceq 'ok') {
            $rootItem = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if (-not $rootItem.PSIsContainer) {
                $errors.Add("声明扫描根已被非目录项占用：$path")
            } else {
                $rootReparseMetadata = Get-BackupRetentionReparseMetadata -Item $rootItem
                $rootIsReparse = [bool]$rootReparseMetadata.isReparsePoint
                if ($rootIsReparse) {
                    $metadataStatus = 'reparse'
                    $reparseAncestor = $path
                    $reparseTarget = $rootReparseMetadata.reparseTarget
                }
            }
            if ($rootIsReparse) {
                $errors.Add("声明扫描根是 reparse point：$path")
            } elseif ($rootItem.PSIsContainer) {
                foreach ($child in @(Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop)) {
                    $reparse = Get-BackupRetentionReparseMetadata -Item $child
                    $items.Add([pscustomobject][ordered]@{
                        path = Get-BackupRetentionCanonicalPath -Path $child.FullName
                        name = $child.Name
                        itemType = if ($child.PSIsContainer) { 'directory' } else { 'file' }
                        isReparsePoint = $reparse.isReparsePoint
                        reparseTarget = $reparse.reparseTarget
                    })
                }
                $completed = $true
            }
        }
    } catch {
        $metadataStatus = 'error'
        $errors.Add($_.Exception.Message)
    }

    $canonicalItems = @($items.ToArray() | Sort-Object path)
    $snapshotJson = ConvertTo-Json -InputObject @($canonicalItems) -Depth 5 -Compress
    if ($null -eq $snapshotJson) { $snapshotJson = '[]' }
    return [pscustomobject][ordered]@{
        rootId = [string]$DeclaredScanRoot.rootId
        path = $path
        rule = [string]$DeclaredScanRoot.rule
        metadataStatus = $metadataStatus
        exists = $exists
        rootIsReparsePoint = $rootIsReparse
        reparseAncestor = $reparseAncestor
        reparseTarget = $reparseTarget
        enumerationStarted = $started
        enumerationCompleted = $completed
        errors = [object[]]$errors.ToArray()
        directChildCount = $canonicalItems.Count
        directChildren = [object[]]$canonicalItems
        snapshotSha256 = Get-BackupRetentionSha256 -Value $snapshotJson
        classificationCount = 0
        classificationCounts = [pscustomobject]@{ candidate = 0; retained = 0; protected = 0; 'delegated-root' = 0; gap = 0 }
    }
}

function Get-BackupRetentionStrictTimestamp {
    param([Parameter(Mandatory)][string]$Name)

    foreach ($definition in @(
        @{ Pattern = '^(?<ts>20\d{6}T\d{6})(?<fraction>\d{3,7})?Z?$'; Format = "yyyyMMdd'T'HHmmss"; Universal = $true },
        @{ Pattern = '^.+[-_](?<ts>20\d{6}T\d{6})(?<fraction>\d{3,7})?Z?$'; Format = "yyyyMMdd'T'HHmmss"; Universal = $true },
        @{ Pattern = '^(?<ts>20\d{6}-\d{6})$'; Format = 'yyyyMMdd-HHmmss'; Universal = $false },
        @{ Pattern = '^.+[-_](?<ts>20\d{6}-\d{6})$'; Format = 'yyyyMMdd-HHmmss'; Universal = $false },
        @{ Pattern = '^(?<ts>20\d{12})$'; Format = 'yyyyMMddHHmmss'; Universal = $false },
        @{ Pattern = '^.+[-_](?<ts>20\d{12})$'; Format = 'yyyyMMddHHmmss'; Universal = $false }
    )) {
        $match = [regex]::Match($Name, $definition.Pattern)
        if (-not $match.Success) { continue }
        try {
            $styles = if ($definition.Universal) { [Globalization.DateTimeStyles]::AssumeUniversal } else { [Globalization.DateTimeStyles]::AssumeLocal }
            $timestamp = [datetime]::ParseExact($match.Groups['ts'].Value, $definition.Format, [Globalization.CultureInfo]::InvariantCulture, $styles).ToUniversalTime()
            if ($match.Groups['fraction'].Success) {
                $timestamp = $timestamp.AddTicks([int64]$match.Groups['fraction'].Value.PadRight(7, '0').Substring(0, 7))
            }
            return [pscustomobject]@{ ok = $true; timestampUtc = $timestamp; source = $match.Value }
        } catch { }
    }
    return [pscustomobject]@{ ok = $false; timestampUtc = $null; source = $null }
}

function Get-BackupRetentionSafeStats {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$IncludeTreeDigest,
        [scriptblock]$StreamResolver = { param($TargetPath) if($IsWindows){@(Get-Item -LiteralPath $TargetPath -Stream * -ErrorAction Stop)}else{@()} }
    )

    $result = [ordered]@{ exists = $false; bytes = [int64]0; mb = 0.0; files = 0; dirs = 0; skillMd = 0; newestUtc = $null; oldestUtc = $null; reparsePointsSkipped = 0; inaccessibleItems = 0; treeSha256 = $null }
    $treeRecords = [Collections.Generic.List[string]]::new()
    $rootPath = Get-BackupRetentionCanonicalPath -Path $Path
    $assertNoNamedStreams = {
        param([string]$TargetPath)
        if(-not$IncludeTreeDigest){return $true}
        try{$streams=@(& $StreamResolver $TargetPath)}catch{$result.inaccessibleItems++;return $false}
        foreach($stream in $streams){
            if($null-eq$stream-or$stream.PSObject.Properties.Name-notcontains'Stream'-or$stream.Stream-isnot[string]){$result.inaccessibleItems++;return $false}
            if($stream.Stream-cne':$DATA'){$result.inaccessibleItems++;return $false}
        }
        return $true
    }
    $addDirectoryRecord = {
        param([string]$RelativePath)
        if (-not $IncludeTreeDigest) { return }
        $treeRecords.Add((ConvertTo-Json -InputObject ([pscustomobject][ordered]@{ relativePath = $RelativePath; itemType = 'directory' }) -Compress))
    }
    $addFileRecord = {
        param([string]$RelativePath,[IO.FileInfo]$File)
        if (-not $IncludeTreeDigest) { return }
        $beforeLength = [int64]$File.Length
        $beforeMtime = $File.LastWriteTimeUtc.ToString('o')
        $stream = [IO.File]::Open($File.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try { $contentSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant() } finally { $stream.Dispose() }
        $after = Get-Item -LiteralPath $File.FullName -Force -ErrorAction Stop
        if (($after.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $after.PSIsContainer -or [int64]$after.Length -ne $beforeLength -or $after.LastWriteTimeUtc.ToString('o') -cne $beforeMtime) {
            throw "文件在 tree digest 期间发生变化：$($File.FullName)"
        }
        $treeRecords.Add((ConvertTo-Json -InputObject ([pscustomobject][ordered]@{ relativePath = $RelativePath; itemType = 'file'; length = $beforeLength; lastWriteUtc = $beforeMtime; contentSha256 = $contentSha256 }) -Compress))
    }
    try {
        $rootItem = Get-Item -LiteralPath $rootPath -Force -ErrorAction Stop
        $result.exists = $true
        if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $result.reparsePointsSkipped++; return [pscustomobject]$result }
        if(-not(& $assertNoNamedStreams $rootPath)){return [pscustomobject]$result}
        $stack = [Collections.Generic.Stack[string]]::new()
        if ($rootItem.PSIsContainer) { & $addDirectoryRecord '.'; $stack.Push($rootItem.FullName) } else {
            $result.files = 1; $result.bytes = [int64]$rootItem.Length
            $result.skillMd = if ($rootItem.Name -ieq 'SKILL.md') { 1 } else { 0 }
            $result.newestUtc = $rootItem.LastWriteTimeUtc.ToString('o'); $result.oldestUtc = $result.newestUtc
            & $addFileRecord '.' $rootItem
        }
        while ($stack.Count -gt 0) {
            $current = $stack.Pop()
            $currentState = Get-BackupRetentionPathChainState -Path $current -TrustedRoot $rootPath
            if ($currentState.status -ceq 'reparse') { $result.reparsePointsSkipped++; continue }
            if ($currentState.status -cne 'ok' -or -not $currentState.exists) { $result.inaccessibleItems++; continue }
            try {
                $currentItem = Get-Item -LiteralPath $current -Force -ErrorAction Stop
                if (($currentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $result.reparsePointsSkipped++; continue }
                if (-not $currentItem.PSIsContainer) { $result.inaccessibleItems++; continue }
                $children = @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)
            } catch { $result.inaccessibleItems++; continue }
            foreach ($child in $children) {
                if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $result.reparsePointsSkipped++; continue }
                if(-not(& $assertNoNamedStreams $child.FullName)){continue}
                $relativePath = [IO.Path]::GetRelativePath($rootPath, $child.FullName).Replace('/', '\')
                if ([IO.Path]::IsPathFullyQualified($relativePath) -or $relativePath -eq '..' -or $relativePath.StartsWith('..\', [StringComparison]::Ordinal)) { $result.inaccessibleItems++; continue }
                $last = $child.LastWriteTimeUtc
                if ($null -eq $result.newestUtc -or $last -gt [datetime]$result.newestUtc) { $result.newestUtc = $last.ToString('o') }
                if ($null -eq $result.oldestUtc -or $last -lt [datetime]$result.oldestUtc) { $result.oldestUtc = $last.ToString('o') }
                if ($child.PSIsContainer) { $result.dirs++; & $addDirectoryRecord $relativePath; $stack.Push($child.FullName) } else {
                    try {
                        & $addFileRecord $relativePath $child
                        $result.files++; $result.bytes += [int64]$child.Length
                        if ($child.Name -ieq 'SKILL.md') { $result.skillMd++ }
                    } catch { $result.inaccessibleItems++ }
                }
            }
        }
    } catch { $result.inaccessibleItems++ }
    $result.mb = [math]::Round(($result.bytes / 1MB), 2)
    if ($IncludeTreeDigest -and $result.exists -and $result.reparsePointsSkipped -eq 0 -and $result.inaccessibleItems -eq 0) {
        $records = [string[]]$treeRecords.ToArray()
        [Array]::Sort($records, [StringComparer]::Ordinal)
        $result.treeSha256 = Get-BackupRetentionSha256 -Value ($records -join "`n")
    }
    return [pscustomobject]$result
}

function New-BackupRetentionCoverageItem {
    param(
        [string]$Path, [AllowNull()][string]$ScanRoot, [string]$ItemType,
        [AllowNull()][object]$PathExists = $true,
        [string]$Disposition, [string]$Reason, [bool]$Manual,
        [bool]$Blocks, [string]$Bucket = '', [string]$GroupKey = '',
        [string]$ProjectRoot = '', [string]$BackupType = '',
        [AllowNull()][object]$Timestamp = $null, [int]$RetainRank = 0,
        [string]$Risk = '低', [AllowNull()][string]$DelegatedScanRoot = $null,
        [AllowNull()][object]$IsReparsePoint = $false, [AllowNull()][string]$ReparseTarget = $null,
        [AllowNull()][string]$ReparseAncestor = $null,
        [AllowNull()][object]$Stats = $null, [string]$CoverageOrigin = 'scan',
        [ValidateSet('ok','reparse','error')][string]$MetadataStatus = 'ok',
        [AllowEmptyCollection()][object[]]$Errors = @()
    )

    $canonicalReparseAncestor = if ([string]::IsNullOrWhiteSpace($ReparseAncestor)) { $null } else { $ReparseAncestor }
    $canonicalReparseTarget = if ([string]::IsNullOrWhiteSpace($ReparseTarget)) { $null } else { $ReparseTarget }
    $blockedBy = if ($Disposition -ceq 'candidate') { @('必须重新生成最新 dry-run', '必须由用户确认 manifest 和路径集合', 'apply 阶段必须二次检查状态指纹') } elseif ($Manual) { @('必须人工确认路径用途和 owner') } else { @() }
    return [pscustomobject][ordered]@{
        path = Get-BackupRetentionCanonicalPath -Path $Path
        scanRoot = if ([string]::IsNullOrWhiteSpace($ScanRoot)) { $null } else { Get-BackupRetentionCanonicalPath -Path $ScanRoot }
        itemType = $ItemType
        pathExists = $PathExists
        coverageOrigin = $CoverageOrigin
        coverageDisposition = $Disposition
        coverageAccounted = $true
        requiresManualReview = $Manual
        blocksCoverage = $Blocks
        reason = $Reason
        rule = if ($Disposition -ceq 'candidate' -or $Disposition -ceq 'retained') { "按项目根和备份类型保留最近项；当前 retainCount 由 policy context 固定。" } elseif ($Manual) { '人工审查。' } else { '显式保护。' }
        bucket = $Bucket
        groupKey = $GroupKey
        projectRoot = $ProjectRoot
        backupType = $BackupType
        timestampUtc = if ($null -eq $Timestamp) { $null } else { $Timestamp.timestampUtc.ToString('o') }
        timestampSource = if ($null -eq $Timestamp) { $null } else { $Timestamp.source }
        retainRank = if ($RetainRank -gt 0) { $RetainRank } else { $null }
        risk = $Risk
        metadataStatus = $MetadataStatus
        errors = [object[]]@($Errors | Where-Object { $null -ne $_ })
        delegatedScanRoot = if ([string]::IsNullOrWhiteSpace($DelegatedScanRoot)) { $null } else { Get-BackupRetentionCanonicalPath -Path $DelegatedScanRoot }
        isReparsePoint = $IsReparsePoint
        reparseTarget = $canonicalReparseTarget
        reparseAncestor = $canonicalReparseAncestor
        reparse = [pscustomobject]@{
            isReparsePoint = $IsReparsePoint
            hasReparsePoint = $IsReparsePoint -is [bool] -and $IsReparsePoint
            firstReparsePoint = if ($null -ne $canonicalReparseAncestor) { $canonicalReparseAncestor } elseif ($IsReparsePoint) { Get-BackupRetentionCanonicalPath -Path $Path } else { $null }
            target = $canonicalReparseTarget
        }
        automaticCandidate = $Disposition -ceq 'candidate'
        selectedByRetention = $Disposition -ceq 'candidate'
        applyEligible = $false
        requiresExplicitAuthorization = $Disposition -ceq 'candidate' -or $Manual
        blockedBy = [object[]]@($blockedBy)
        stats = $Stats
    }
}

function Test-BackupRetentionDirectChild {
    param([string]$Parent, [string]$Child)
    try {
        $parentPath = Get-BackupRetentionCanonicalPath $Parent
        $childPath = Get-BackupRetentionCanonicalPath $Child
        $childParent = [IO.Directory]::GetParent($childPath)
        return $null -ne $childParent -and $childParent.FullName.TrimEnd('\') -ieq $parentPath.TrimEnd('\')
    } catch { return $false }
}

function Test-BackupRetentionDelegationGraph {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$DeclaredScanRoots,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$CoverageItems
    )

    $errors = [Collections.Generic.List[string]]::new()
    $roots = @{}
    foreach ($root in $DeclaredScanRoots) {
        $path = Get-BackupRetentionCanonicalPath ([string]$root.path)
        $roots[$path.ToLowerInvariant()] = $root
    }
    $edges = @{}
    $parentsByTarget = @{}
    foreach ($item in @($CoverageItems | Where-Object { $_.coverageDisposition -ceq 'delegated-root' })) {
        $parent = Get-BackupRetentionCanonicalPath ([string]$item.scanRoot)
        $itemPath = Get-BackupRetentionCanonicalPath ([string]$item.path)
        $target = Get-BackupRetentionCanonicalPath ([string]$item.delegatedScanRoot)
        if ($parent -ieq $target) { $errors.Add("委托不得自引用：$parent") }
        if ($itemPath -ine $target) { $errors.Add("委托目标必须等于当前子项：$itemPath") }
        if (-not (Test-BackupRetentionDirectChild -Parent $parent -Child $target)) { $errors.Add("委托目标必须是父根的直接子项：$target") }
        $targetKey = $target.ToLowerInvariant(); $parentKey = $parent.ToLowerInvariant()
        if (-not $roots.ContainsKey($targetKey)) { $errors.Add("委托目标不在 declaredScanRoots：$target") }
        elseif (($roots[$targetKey].PSObject.Properties.Name -contains 'exists' -and -not [bool]$roots[$targetKey].exists) -or
            ($roots[$targetKey].PSObject.Properties.Name -contains 'enumerationCompleted' -and -not [bool]$roots[$targetKey].enumerationCompleted)) {
            $errors.Add("委托目标不存在或未成功枚举：$target")
        }
        if ($parentsByTarget.ContainsKey($targetKey) -and $parentsByTarget[$targetKey] -ine $parentKey) { $errors.Add("被委托根不得有多个父级：$target") }
        $parentsByTarget[$targetKey] = $parentKey
        if (-not $edges.ContainsKey($parentKey)) { $edges[$parentKey] = [Collections.Generic.List[string]]::new() }
        $edges[$parentKey].Add($targetKey)
    }

    foreach ($start in @($edges.Keys)) {
        $stack = [Collections.Generic.Stack[object]]::new()
        $stack.Push([pscustomobject]@{ node = $start; ancestry = @() })
        while ($stack.Count -gt 0) {
            $frame = $stack.Pop()
            if (@($frame.ancestry | Where-Object { $_ -ceq $frame.node }).Count -gt 0) {
                $errors.Add("委托图不得有环：$start")
                break
            }
            if (-not $edges.ContainsKey($frame.node)) { continue }
            $nextAncestry = @($frame.ancestry) + @($frame.node)
            foreach ($target in @($edges[$frame.node])) {
                $stack.Push([pscustomobject]@{ node = $target; ancestry = $nextAncestry })
            }
        }
    }
    return [pscustomobject]@{ valid = $errors.Count -eq 0; errors = [object[]]$errors.ToArray() }
}

function Get-BackupRetentionGuardrailItems {
    param(
        [Parameter(Mandatory)][psobject]$PolicyContext,
        [Parameter(Mandatory)][scriptblock]$PathChainResolver
    )

    $definitions = @(
        @{ Relative = 'skills'; Reason = '当前用户 skill 活跃层，不能按备份清理。'; Manual = $false },
        @{ Relative = 'plugins\cache'; Reason = '当前插件缓存活跃层，不能按备份清理。'; Manual = $false },
        @{ Relative = 'account_backup'; Reason = '账号备份根不能整体删除。'; Manual = $false },
        @{ Relative = 'account_backup\windows\plugins'; Reason = 'runtime 共享 plugins 目录，保护。'; Manual = $false },
        @{ Relative = 'account_backup\windows\cache'; Reason = 'runtime 共享 cache 目录，保护。'; Manual = $false },
        @{ Relative = 'account_backup\windows\sqlite'; Reason = 'runtime 共享 sqlite 目录，保护。'; Manual = $false },
        @{ Relative = 'account_backup\windows\auth.json'; Reason = '账号敏感文件，保护。'; Manual = $false },
        @{ Relative = 'account_backup\windows\profile.json'; Reason = '账号敏感文件，保护。'; Manual = $false },
        @{ Relative = 'account_backup\windows\install_state.json'; Reason = '安装状态文件，保护。'; Manual = $false },
        @{ Relative = 'account_backup\windows\quota_cache.json'; Reason = '配额状态文件，保护。'; Manual = $false },
        @{ Relative = 'backups'; Reason = '全局 backups 根混有不同回滚语义，仅人工审查。'; Manual = $true },
        @{ Relative = 'run-evidence'; Reason = '运行证据根不得自动清理。'; Manual = $true },
        @{ Relative = 'account_backup\_autosave'; Reason = '账号自动快照是回滚边界，仅人工审查。'; Manual = $true }
        @{ Relative = 'account_backup\windows\login_runtime\plugins'; Reason = 'login runtime 插件目录邻近账号运行时，仅人工审查。'; Manual = $true },
        @{ Relative = 'account_backup\windows\login_runtime\.tmp\plugins'; Reason = 'login runtime 中间态不得自动 prune。'; Manual = $true },
        @{ Relative = 'account_backup\windows\refresh_runtime\plugins'; Reason = 'refresh runtime 共享插件目录，仅人工审查。'; Manual = $true },
        @{ Relative = 'account_backup\windows\refresh_runtime\.tmp'; Reason = 'refresh runtime 中间态不得自动 prune。'; Manual = $true },
        @{ Relative = 'skills-backups'; Reason = '旧 skill 备份可能仍是回滚边界，仅人工审查。'; Manual = $true },
        @{ Relative = '.backups'; Reason = '旧本地备份用途不明，仅人工审查。'; Manual = $true },
        @{ Relative = '.tmp\bundled-marketplaces'; Reason = '全局 marketplace staging 可能在使用中，仅人工审查。'; Manual = $true }
    )
    $items = [Collections.Generic.List[object]]::new()
    foreach ($definition in $definitions) {
        $path = Join-Path $PolicyContext.CodexRoot $definition.Relative
        $chain = Resolve-BackupRetentionPathChainState -Path $path -TrustedRoot $PolicyContext.DDriveRoot -PathChainResolver $PathChainResolver
        $stats = if ($chain.status -ceq 'ok') {
            $null
        } else {
            [pscustomobject]@{ exists = if ($chain.exists -is [bool]) { $chain.exists } else { $null }; bytes = [int64]0; mb = 0.0; files = 0; dirs = 0; skillMd = 0; newestUtc = $null; oldestUtc = $null; reparsePointsSkipped = if ($chain.status -ceq 'reparse') { 1 } else { 0 }; inaccessibleItems = if ($chain.status -ceq 'error') { 1 } else { 0 }; treeSha256 = $null }
        }
        $metadataFailed = $chain.status -cne 'ok'
        $manual = [bool]$definition.Manual -or $metadataFailed
        $risk = if ($manual) { '高' } else { '低' }
        $errors = if ($chain.status -ceq 'reparse') { @("protected path ancestor is reparse point: $($chain.reparseAncestor)") } elseif ($chain.status -ceq 'error') { @([string]$chain.error) } else { @() }
        $reason = if ($metadataFailed) { "$($definition.Reason) reparse metadata 不可信，失败关闭。" } else { $definition.Reason }
        $isReparse = if ($chain.status -ceq 'reparse') { $true } elseif ($chain.status -ceq 'error') { $null } else { $false }
        $items.Add((New-BackupRetentionCoverageItem -Path $path -ScanRoot $null -ItemType 'policy-path' -PathExists $chain.exists -Disposition 'protected' -Reason $reason -Manual $manual -Blocks $metadataFailed -Risk $risk -Stats $stats -CoverageOrigin 'policy-guardrail' -MetadataStatus $chain.status -IsReparsePoint $isReparse -ReparseAncestor $chain.reparseAncestor -ReparseTarget $chain.reparseTarget -Errors $errors))
    }
    $legacy = Join-Path $PolicyContext.DDriveRoot '.codex-c-backups'
    $legacyChain = Resolve-BackupRetentionPathChainState -Path $legacy -TrustedRoot $PolicyContext.DDriveRoot -PathChainResolver $PathChainResolver
    $legacyStats = if ($legacyChain.status -ceq 'ok') { $null } else { [pscustomobject]@{ exists = if ($legacyChain.exists -is [bool]) { $legacyChain.exists } else { $null }; bytes = [int64]0; mb = 0.0; files = 0; dirs = 0; skillMd = 0; newestUtc = $null; oldestUtc = $null; reparsePointsSkipped = if ($legacyChain.status -ceq 'reparse') { 1 } else { 0 }; inaccessibleItems = if ($legacyChain.status -ceq 'error') { 1 } else { 0 }; treeSha256 = $null } }
    $legacyFailed = $legacyChain.status -cne 'ok'
    $legacyErrors = if ($legacyChain.status -ceq 'reparse') { @("protected path ancestor is reparse point: $($legacyChain.reparseAncestor)") } elseif ($legacyChain.status -ceq 'error') { @([string]$legacyChain.error) } else { @() }
    $legacyIsReparse = if ($legacyChain.status -ceq 'reparse') { $true } elseif ($legacyChain.status -ceq 'error') { $null } else { $false }
    $items.Add((New-BackupRetentionCoverageItem -Path $legacy -ScanRoot $null -ItemType 'policy-path' -PathExists $legacyChain.exists -Disposition 'protected' -Reason '历史迁移备份可能有审计价值，仅人工审查。' -Manual $true -Blocks $legacyFailed -Risk '高' -Stats $legacyStats -CoverageOrigin 'policy-guardrail' -MetadataStatus $legacyChain.status -IsReparsePoint $legacyIsReparse -ReparseAncestor $legacyChain.reparseAncestor -ReparseTarget $legacyChain.reparseTarget -Errors $legacyErrors))
    $agentsEvidence = 'D:\agents\run-evidence'
    $agentsChain = Resolve-BackupRetentionPathChainState -Path $agentsEvidence -TrustedRoot 'D:\agents' -PathChainResolver $PathChainResolver
    $agentsStats = if ($agentsChain.status -ceq 'ok') { $null } else { [pscustomobject]@{ exists = if ($agentsChain.exists -is [bool]) { $agentsChain.exists } else { $null }; bytes = [int64]0; mb = 0.0; files = 0; dirs = 0; skillMd = 0; newestUtc = $null; oldestUtc = $null; reparsePointsSkipped = if ($agentsChain.status -ceq 'reparse') { 1 } else { 0 }; inaccessibleItems = if ($agentsChain.status -ceq 'error') { 1 } else { 0 }; treeSha256 = $null } }
    $agentsFailed = $agentsChain.status -cne 'ok'
    $agentsErrors = if ($agentsChain.status -ceq 'reparse') { @("protected path ancestor is reparse point: $($agentsChain.reparseAncestor)") } elseif ($agentsChain.status -ceq 'error') { @([string]$agentsChain.error) } else { @() }
    $agentsIsReparse = if ($agentsChain.status -ceq 'reparse') { $true } elseif ($agentsChain.status -ceq 'error') { $null } else { $false }
    $items.Add((New-BackupRetentionCoverageItem -Path $agentsEvidence -ScanRoot $null -ItemType 'policy-path' -PathExists $agentsChain.exists -Disposition 'protected' -Reason '迁移后运行证据根不得自动清理，仅人工审查。' -Manual $true -Blocks $agentsFailed -Risk '高' -Stats $agentsStats -CoverageOrigin 'policy-guardrail' -MetadataStatus $agentsChain.status -IsReparsePoint $agentsIsReparse -ReparseAncestor $agentsChain.reparseAncestor -ReparseTarget $agentsChain.reparseTarget -Errors $agentsErrors))
    return [object[]]$items.ToArray()
}

function Invoke-BackupRetentionEvaluation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$PolicyContext,
        [scriptblock]$PathChainResolver = { param($Path, $Root) Get-BackupRetentionPathChainState -Path $Path -TrustedRoot $Root }
    )

    foreach ($required in @('artifactMode', 'CodexRoot', 'DDriveRoot', 'retainCount', 'policyId', 'policyVersion')) {
        if ($PolicyContext.PSObject.Properties.Name -notcontains $required) { throw "PolicyContext 缺少必需字段：$required" }
    }
    if ([string]$PolicyContext.policyId -cne 'env-governance.backup-retention' -or [int]$PolicyContext.policyVersion -ne 3) {
        throw 'PolicyContext policyId/policyVersion 不受信任。'
    }
    $PolicyContext = New-BackupRetentionPolicyContext -ArtifactMode ([string]$PolicyContext.artifactMode) -CodexRoot ([string]$PolicyContext.CodexRoot) -DDriveRoot ([string]$PolicyContext.DDriveRoot) -RetainCount ([int]$PolicyContext.retainCount)

    $declared = @(Get-BackupRetentionDeclaredScanRoots -PolicyContext $PolicyContext)
    $evaluated = @($declared | ForEach-Object { Get-BackupRetentionRootSnapshot -DeclaredScanRoot $_ -TrustedRoot $PolicyContext.DDriveRoot -PathChainResolver $PathChainResolver })
    $items = [Collections.Generic.List[object]]::new()
    $pending = [Collections.Generic.List[object]]::new()
    $manualBackupsStateNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @(Get-BackupRetentionKnownBackupsStateManualDirectoryNames)) {
        [void]$manualBackupsStateNames.Add($name)
    }

    foreach ($root in $evaluated) {
        if (-not $root.enumerationCompleted -or @($root.errors).Count -gt 0) {
            $rootReason = if ($root.rootIsReparsePoint) { '声明扫描根是 reparse point，覆盖失败关闭。' } else { '声明扫描根枚举未完成，覆盖失败关闭。' }
            $rootItemIsReparse = if ($root.metadataStatus -ceq 'error') { $null } else { [bool]$root.rootIsReparsePoint }
            $items.Add((New-BackupRetentionCoverageItem -Path $root.path -ScanRoot $null -ItemType 'scan-root' -PathExists $root.exists -Disposition 'gap' -Reason $rootReason -Manual $true -Blocks $true -Risk '高' -IsReparsePoint $rootItemIsReparse -ReparseAncestor $root.reparseAncestor -ReparseTarget $root.reparseTarget -CoverageOrigin 'scan-root-error' -MetadataStatus $root.metadataStatus -Errors @($root.errors)))
        }
        foreach ($child in @($root.directChildren)) {
            if ($child.isReparsePoint) {
                $items.Add((New-BackupRetentionCoverageItem -Path $child.path -ScanRoot $root.path -ItemType $child.itemType -Disposition 'gap' -Reason '直接子项是 reparse point，不能进入保留规则。' -Manual $true -Blocks $true -Risk '高' -IsReparsePoint $true -ReparseAncestor $child.path -ReparseTarget $child.reparseTarget -MetadataStatus 'reparse' -Errors @("direct child is reparse point: $($child.path)")))
                continue
            }

            if ($root.rule -ceq 'backups-state-root') {
                if ($child.name -ceq 'provider-sync' -and $child.itemType -ceq 'directory') {
                    $items.Add((New-BackupRetentionCoverageItem -Path $child.path -ScanRoot $root.path -ItemType $child.itemType -Disposition 'delegated-root' -Reason '由更窄的 provider-sync 扫描根负责分类。' -Manual $false -Blocks $false -DelegatedScanRoot $child.path))
                    continue
                }
                if ($child.itemType -ceq 'directory' -and $manualBackupsStateNames.Contains($child.name)) {
                    $items.Add((New-BackupRetentionCoverageItem -Path $child.path -ScanRoot $root.path -ItemType $child.itemType -Disposition 'protected' -Reason '受管主机维护回滚状态，仅人工审查。' -Manual $true -Blocks $false -Risk '高' -CoverageOrigin 'policy-guardrail'))
                    continue
                }
                $sidecarMatch = [regex]::Match($child.name, '^(?<base>config\.toml|\.codex-global-state\.json)-(?<ts>20\d{6}T\d{6}(?:\d{3,7})?Z)$')
                $backupType = if ($sidecarMatch.Success -and $sidecarMatch.Groups['base'].Value -ceq 'config.toml') { 'config.toml-sidecar' } elseif ($sidecarMatch.Success) { 'global-state-sidecar' } else { $null }
                if ($child.itemType -cne 'file' -or $null -eq $backupType) {
                    $items.Add((New-BackupRetentionCoverageItem -Path $child.path -ScanRoot $root.path -ItemType $child.itemType -Disposition 'gap' -Reason '未知 backups_state 直接子项。' -Manual $true -Blocks $true -Risk '中'))
                    continue
                }
                $timestamp = Get-BackupRetentionStrictTimestamp -Name $child.name
                if (-not $timestamp.ok) {
                    $items.Add((New-BackupRetentionCoverageItem -Path $child.path -ScanRoot $root.path -ItemType $child.itemType -Disposition 'gap' -Reason '无法严格解析侧车备份时间戳。' -Manual $true -Blocks $true -Risk '中' -GroupKey ".codex/backups_state/root-sidecars::$backupType" -BackupType $backupType))
                    continue
                }
                $pending.Add([pscustomobject]@{ child = $child; root = $root; timestamp = $timestamp; bucket = '按组保留最近 5 个'; groupKey = ".codex/backups_state/root-sidecars::$backupType"; projectRoot = '.codex/backups_state/root-sidecars'; backupType = $backupType; risk = '低'; reason = '侧车备份按类型保留。' })
                continue
            }

            if ($child.itemType -cne 'directory') {
                $items.Add((New-BackupRetentionCoverageItem -Path $child.path -ScanRoot $root.path -ItemType $child.itemType -Disposition 'gap' -Reason '保留规则扫描根中出现未分类文件。' -Manual $true -Blocks $true -Risk '中'))
                continue
            }

            $timestamp = Get-BackupRetentionStrictTimestamp -Name $child.name
            $backupType = $null; $projectRoot = ''; $bucket = '按组保留最近 5 个'; $risk = '低'; $reason = ''
            switch ($root.rule) {
                'provider-sync' {
                    if ($child.name -match '^20\d{6}T\d{6}(?:\d{3,7})?Z?$') { $backupType = 'provider-sync' }
                    $projectRoot = '.codex/backups_state/provider-sync'; $reason = 'provider-sync 状态备份按固定数量保留。'
                }
                'codex-switch' {
                    $backupType = 'codex-switch-installed-binary'; $projectRoot = 'apps/codex_switch/backups'; $risk = '中'; $bucket = 'codex_switch 安装回滚备份'; $reason = 'codex_switch 安装版回滚备份超过保留数。'
                    if (-not (Test-Path -LiteralPath (Join-Path $child.path 'codex_switch.exe') -PathType Leaf) -or -not (Test-Path -LiteralPath (Join-Path $child.path 'WebView2Loader.dll') -PathType Leaf)) { $backupType = $null }
                }
            }
            if ([string]::IsNullOrWhiteSpace($backupType) -or -not $timestamp.ok) {
                $items.Add((New-BackupRetentionCoverageItem -Path $child.path -ScanRoot $root.path -ItemType $child.itemType -Disposition 'gap' -Reason '目录不符合严格备份类型、时间戳或完整性规则。' -Manual $true -Blocks $true -Risk '中'))
                continue
            }
            $pending.Add([pscustomobject]@{ child = $child; root = $root; timestamp = $timestamp; bucket = $bucket; groupKey = "$projectRoot::$backupType"; projectRoot = $projectRoot; backupType = $backupType; risk = $risk; reason = $reason })
        }
    }

    foreach ($group in @($pending.ToArray() | Group-Object groupKey)) {
        $ordered = @($group.Group | Sort-Object @{ Expression = { $_.timestamp.timestampUtc }; Descending = $true }, @{ Expression = { $_.child.name }; Descending = $true })
        for ($index = 0; $index -lt $ordered.Count; $index++) {
            $record = $ordered[$index]
            $rank = $index + 1
            $chain = Resolve-BackupRetentionPathChainState -Path $record.child.path -TrustedRoot $PolicyContext.DDriveRoot -PathChainResolver $PathChainResolver
            if ($chain.status -cne 'ok') {
                $reason = if ($chain.status -ceq 'reparse') { '候选/保留路径在统计前的完整父链命中 reparse point。' } else { "候选/保留路径 reparse metadata 读取失败：$($chain.error)" }
                $candidateIsReparse = if ($chain.status -ceq 'reparse') { $true } else { $null }
                $items.Add((New-BackupRetentionCoverageItem -Path $record.child.path -ScanRoot $record.root.path -ItemType $record.child.itemType -Disposition 'gap' -Reason $reason -Manual $true -Blocks $true -Risk '高' -GroupKey $record.groupKey -ProjectRoot $record.projectRoot -BackupType $record.backupType -Timestamp $record.timestamp -RetainRank $rank -IsReparsePoint $candidateIsReparse -ReparseAncestor $chain.reparseAncestor -ReparseTarget $chain.reparseTarget -MetadataStatus $chain.status -Errors @($reason)))
                continue
            }
            $disposition = if ($rank -le [int]$PolicyContext.retainCount) { 'retained' } else { 'candidate' }
            $stats = Get-BackupRetentionSafeStats -Path $record.child.path -IncludeTreeDigest:($disposition -ceq 'candidate')
            if ($stats.reparsePointsSkipped -gt 0 -or $stats.inaccessibleItems -gt 0 -or ($disposition -ceq 'candidate' -and $stats.treeSha256 -notmatch '^[0-9a-f]{64}$')) {
                $items.Add((New-BackupRetentionCoverageItem -Path $record.child.path -ScanRoot $record.root.path -ItemType $record.child.itemType -Disposition 'gap' -Reason '目录内部存在 reparse point 或不可访问项。' -Manual $true -Blocks $true -Risk '高' -GroupKey $record.groupKey -ProjectRoot $record.projectRoot -BackupType $record.backupType -Timestamp $record.timestamp -RetainRank $rank -Stats $stats))
                continue
            }
            $items.Add((New-BackupRetentionCoverageItem -Path $record.child.path -ScanRoot $record.root.path -ItemType $record.child.itemType -Disposition $disposition -Reason $record.reason -Manual $false -Blocks $false -Bucket $record.bucket -GroupKey $record.groupKey -ProjectRoot $record.projectRoot -BackupType $record.backupType -Timestamp $record.timestamp -RetainRank $rank -Risk $record.risk -Stats $stats))
        }
    }

    foreach ($guardrail in @(Get-BackupRetentionGuardrailItems -PolicyContext $PolicyContext -PathChainResolver $PathChainResolver)) { $items.Add($guardrail) }
    $coverageItems = @($items.ToArray() | Sort-Object @{ Expression = { if ($null -eq $_.scanRoot) { '~' } else { $_.scanRoot } } }, path)

    foreach ($root in $evaluated) {
        $rootItems = @($coverageItems | Where-Object { $null -ne $_.scanRoot -and $_.scanRoot -ieq $root.path })
        $root.classificationCount = $rootItems.Count
        $counts = [ordered]@{ candidate = 0; retained = 0; protected = 0; 'delegated-root' = 0; gap = 0 }
        foreach ($item in $rootItems) { $counts[$item.coverageDisposition] = [int]$counts[$item.coverageDisposition] + 1 }
        $root.classificationCounts = [pscustomobject]$counts
    }

    $accounted = $true
    foreach ($root in $evaluated) {
        $snapshotPaths = @($root.directChildren | ForEach-Object { $_.path.ToLowerInvariant() } | Sort-Object)
        $ledgerPaths = @($coverageItems | Where-Object { $null -ne $_.scanRoot -and $_.scanRoot -ieq $root.path } | ForEach-Object { $_.path.ToLowerInvariant() } | Sort-Object)
        if ($snapshotPaths.Count -ne $ledgerPaths.Count -or (Compare-Object -ReferenceObject $snapshotPaths -DifferenceObject $ledgerPaths).Count -gt 0 -or @($ledgerPaths | Group-Object | Where-Object Count -ne 1).Count -gt 0) {
            $accounted = $false
            break
        }
    }
    $graph = Test-BackupRetentionDelegationGraph -DeclaredScanRoots $evaluated -CoverageItems $coverageItems
    $blocked = @($coverageItems | Where-Object blocksCoverage).Count -gt 0
    $rootFailure = @($evaluated | Where-Object { -not $_.enumerationCompleted -or @($_.errors).Count -gt 0 }).Count -gt 0
    $complete = $accounted -and $graph.valid -and -not $blocked -and -not $rootFailure

    $candidates = @($coverageItems | Where-Object { $_.coverageDisposition -ceq 'candidate' })
    $retained = @($coverageItems | Where-Object { $_.coverageDisposition -ceq 'retained' })
    $protected = @($coverageItems | Where-Object { $_.coverageDisposition -ceq 'protected' })
    $manual = @($coverageItems | Where-Object requiresManualReview)
    $gaps = @($coverageItems | Where-Object { $_.coverageDisposition -ceq 'gap' } | ForEach-Object { [pscustomobject]@{ path = $_.path; scanRoot = $_.scanRoot; reason = $_.reason } })
    $errors = @($evaluated | ForEach-Object { $_.errors } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) + @($graph.errors)

    return [pscustomobject][ordered]@{
        declaredScanRoots = [object[]]$declared
        evaluatedRoots = [object[]]$evaluated
        coverageItems = [object[]]$coverageItems
        candidates = [object[]]$candidates
        retainedItems = [object[]]$retained
        protected = [object[]]$protected
        manualReview = [object[]]$manual
        unclassifiedCoverageGaps = [object[]]$gaps
        coverageAccounted = $accounted
        coverageComplete = $complete
        coverageNotes = @('覆盖证明仅适用于显式 declaredScanRoots，不声称扫描全盘。', '每个成功枚举的直接子项恰好分类一次。', 'policy-guardrail 路径只记录根路径元数据，不递归统计。')
        errors = [object[]]$errors
        delegationGraph = $graph
    }
}
