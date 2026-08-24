[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Check', 'Repair', 'Remove')]
    [string]$Mode,
    [switch]$Json,
    [string]$FixtureRoot,
    [string]$FixturePolicyPath,
    [string]$FixtureStatePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$managedRoot = Join-Path $projectRoot 'managed\remote-plugin-catalog-guard'
$runtimeSourcePath = Join-Path $managedRoot 'CodexRemotePluginCatalogGuard.ps1'
$deployedRoot = 'D:\Codex\.codex\catalog-guard'
$deployedStateRoot = Join-Path $deployedRoot 'state'
$deployedStatePath = Join-Path $deployedStateRoot 'state.json'
$catalogRoot = 'D:\Codex\.codex\cache\remote_plugin_catalog'
$evidenceRoot = 'D:\Codex\.codex\run-evidence\remote-plugin-catalog-guard'
$pwshPath = 'D:\Codex\tools\PowerShell\7.6.5\pwsh.exe'
$pythonwPath = 'D:\Codex\tools\python314-official\pythonw.exe'
$taskName = 'Codex Remote Plugin Catalog Guard'
$taskPath = '\'
$taskDescription = 'Managed by D:\agents\projects\统一环境\scripts\Invoke-CodexRemotePluginCatalogGuard.ps1; owner=codex-remote-plugin-catalog-guard-v1'
$maintenanceMutexName = 'CodexRemotePluginCatalogGuardMaintenanceV2'
$watchMutexName = 'CodexRemotePluginCatalogGuardV2'
$stopEventName = 'CodexRemotePluginCatalogGuardStopV2'
$testModeEnvironment = 'CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_MODE'
$utf8Strict = [Text.UTF8Encoding]::new($false, $true)
$utf8NoBom = [Text.UTF8Encoding]::new($false)
$artifactDefinitions = @(
    [pscustomobject][ordered]@{ name = 'CodexRemotePluginCatalogGuard.ps1'; source = Join-Path $managedRoot 'CodexRemotePluginCatalogGuard.ps1'; target = Join-Path $deployedRoot 'CodexRemotePluginCatalogGuard.ps1' }
    [pscustomobject][ordered]@{ name = 'policy.json'; source = Join-Path $managedRoot 'policy.json'; target = Join-Path $deployedRoot 'policy.json' }
    [pscustomobject][ordered]@{ name = 'CodexHookHandleBoundIO.cs'; source = Join-Path $projectRoot 'scripts\lib\CodexHookHandleBoundIO.cs'; target = Join-Path $deployedRoot 'CodexHookHandleBoundIO.cs' }
    [pscustomobject][ordered]@{ name = 'hidden-console-launcher.py'; source = Join-Path $projectRoot 'managed\codex-hooks\hooks\lib\hidden-console-launcher.py'; target = Join-Path $deployedRoot 'hidden-console-launcher.py' }
)

function Get-Sha256Hex {
    param([byte[]]$Bytes)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function New-CrossSessionCurrentUserOptions {
    $options = [Threading.NamedWaitHandleOptions]::new()
    $options.CurrentUserOnly = $true
    $options.CurrentSessionOnly = $false
    return $options
}

function Assert-DPathWithoutReparse {
    param([string]$Path, [switch]$RequireLeaf)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetPathRoot($fullPath) -ine 'D:\') { throw '受管路径必须位于 D 盘。' }
    $current = [IO.Path]::GetPathRoot($fullPath)
    foreach ($segment in $fullPath.Substring($current.Length).Split(@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar), [StringSplitOptions]::RemoveEmptyEntries)) {
        $current = Join-Path $current $segment
        if (-not [IO.File]::Exists($current) -and -not [IO.Directory]::Exists($current)) { continue }
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw '受管路径包含 reparse point。' }
    }
    if ($RequireLeaf -and -not [IO.File]::Exists($fullPath) -and -not [IO.Directory]::Exists($fullPath)) { throw '受管路径不存在。' }
    return $fullPath
}

function New-SafeDirectory {
    param([string]$Path)
    $fullPath = Assert-DPathWithoutReparse -Path $Path
    if (-not [IO.Directory]::Exists($fullPath)) { [void][IO.Directory]::CreateDirectory($fullPath) }
    return (Assert-DPathWithoutReparse -Path $fullPath -RequireLeaf)
}

function Get-SafeFileSnapshot {
    param([string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    $directoryGuard = $null
    $lease = $null
    try {
        $directoryGuard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire($parent, $parent, $false)
        $lease = $directoryGuard.AcquireTargetFileLease($fullPath)
        [byte[]]$bytes = $lease.SnapshotBytes
        $bytesHash = Get-Sha256Hex -Bytes $bytes
        $handleHash = [Convert]::ToHexString($lease.ComputeSha256FromHandle()).ToLowerInvariant()
        if ($bytesHash -cne $handleHash) { throw '受管文件读取期间哈希漂移。' }
        return [pscustomobject][ordered]@{
            path = $fullPath
            bytes = $bytes
            sha256 = $bytesHash
            identity = @([string]$lease.VolumeSerialNumber, [string]$lease.FileIndex)
        }
    } finally {
        if ($null -ne $lease) { $lease.Dispose() }
        if ($null -ne $directoryGuard) { $directoryGuard.Dispose() }
    }
}

function Publish-Artifact {
    param([object]$Definition, [object]$BeforeFact)
    $source = Get-SafeFileSnapshot -Path $Definition.source
    $parent = New-SafeDirectory -Path (Split-Path -Parent $Definition.target)
    $directoryGuard = $null
    $targetLease = $null
    $tempFile = $null
    $tempPath = Join-Path $parent (".catalog-guard-deploy-{0}.tmp" -f ([guid]::NewGuid().ToString('N')))
    $renamed = $false
    try {
        $directoryGuard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire($parent, $parent, $false)
        $tempFile = $directoryGuard.CreateTempFile($tempPath)
        $tempFile.WriteAndFlush($source.bytes)
        $replace = [IO.File]::Exists($Definition.target)
        if ($replace) {
            if ($BeforeFact.state -cne 'mismatch' -and $BeforeFact.state -cne 'matching') { throw '既有受管 artifact 状态不可安全替换。' }
            $targetLease = $directoryGuard.AcquireTargetFileLease($Definition.target)
            $currentHash = Get-Sha256Hex -Bytes $targetLease.SnapshotBytes
            if ($currentHash -cne $BeforeFact.deployedSha256) { throw '受管 artifact 临写前漂移。' }
            $currentIdentity = @([string]$targetLease.VolumeSerialNumber, [string]$targetLease.FileIndex)
            if ($currentIdentity[0] -cne $BeforeFact.deployedIdentity[0] -or $currentIdentity[1] -cne $BeforeFact.deployedIdentity[1]) { throw '受管 artifact 临写前 identity 漂移。' }
            $targetLease.DeleteWithPosixSemantics()
            $targetLease.Dispose()
            $targetLease = $null
        } elseif ($BeforeFact.state -cne 'missing') {
            throw '受管 artifact missing 状态漂移。'
        }
        try {
            $tempFile.RenameTo($Definition.target, $false)
        } catch {
            if ([IO.File]::Exists($Definition.target)) { throw '受管 artifact 发布竞态：目标路径已被其他写入者重建。' }
            throw
        }
        $renamed = $true
        if ((Get-Sha256Hex -Bytes $tempFile.ReadAllBytesFromHandle()) -cne $source.sha256) { throw '受管 artifact 发布后哈希不一致。' }
    } finally {
        if ($null -ne $targetLease) { $targetLease.Dispose() }
        if ($null -ne $tempFile) {
            if (-not $renamed) { try { $tempFile.DeleteWithPosixSemantics() } catch {} }
            $tempFile.Dispose()
        }
        if ($null -ne $directoryGuard) { $directoryGuard.Dispose() }
        if (-not $renamed -and [IO.File]::Exists($tempPath)) { [IO.File]::Delete($tempPath) }
    }
}

function Remove-ManagedFile {
    param([string]$Path, [string]$ExpectedSha256)
    if (-not [IO.File]::Exists($Path)) { return $false }
    $parent = Split-Path -Parent $Path
    $directoryGuard = $null
    $lease = $null
    try {
        $directoryGuard = [CodexHookGovernance.VerifiedDirectoryChainGuard]::Acquire($parent, $parent, $false)
        $lease = $directoryGuard.AcquireTargetFileLease($Path)
        if ((Get-Sha256Hex -Bytes $lease.SnapshotBytes) -cne $ExpectedSha256) { throw 'Remove 前受管 artifact 漂移。' }
        $lease.DeleteWithPosixSemantics()
        return $true
    } finally {
        if ($null -ne $lease) { $lease.Dispose() }
        if ($null -ne $directoryGuard) { $directoryGuard.Dispose() }
    }
}

function Get-ArtifactFacts {
    $facts = [Collections.Generic.List[object]]::new()
    foreach ($definition in $artifactDefinitions) {
        $source = Get-SafeFileSnapshot -Path $definition.source
        if (-not [IO.File]::Exists($definition.target)) {
            $facts.Add([pscustomobject][ordered]@{ name = $definition.name; sourceSha256 = $source.sha256; deployedSha256 = $null; deployedIdentity = @(); state = 'missing' })
            continue
        }
        try {
            $deployed = Get-SafeFileSnapshot -Path $definition.target
            $facts.Add([pscustomobject][ordered]@{
                name = $definition.name
                sourceSha256 = $source.sha256
                deployedSha256 = $deployed.sha256
                deployedIdentity = @($deployed.identity)
                state = if ($source.sha256 -ceq $deployed.sha256) { 'matching' } else { 'mismatch' }
            })
        } catch {
            $facts.Add([pscustomobject][ordered]@{ name = $definition.name; sourceSha256 = $source.sha256; deployedSha256 = $null; deployedIdentity = @(); state = 'unsafe' })
        }
    }
    return @($facts)
}

function Quote-TaskArgument {
    param([string]$Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Get-DesiredTaskArguments {
    $launcherPath = Join-Path $deployedRoot 'hidden-console-launcher.py'
    $guardPath = Join-Path $deployedRoot 'CodexRemotePluginCatalogGuard.ps1'
    return @(
        '-I', '-S', '-B', '-X', 'utf8',
        (Quote-TaskArgument -Value $launcherPath),
        (Quote-TaskArgument -Value $pwshPath),
        '-NoLogo', '-NoProfile', '-NonInteractive',
        '-File', (Quote-TaskArgument -Value $guardPath),
        '-Mode', 'Watch'
    ) -join ' '
}

function Get-TaskFacts {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $tasks = @(Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue)
    if ($tasks.Count -eq 0) {
        return [pscustomobject][ordered]@{ exists = $false; owned = $false; configurationOk = $false; state = 'Missing'; currentUser = $currentUser }
    }
    if ($tasks.Count -ne 1) { throw '同名计划任务不唯一。' }
    $task = $tasks[0]
    $actions = @($task.Actions)
    $triggers = @($task.Triggers)
    $owned = $task.Description -ceq $taskDescription
    $actionOk = $actions.Count -eq 1 -and
        [string]$actions[0].Execute -ceq $pythonwPath -and
        [string]$actions[0].Arguments -ceq (Get-DesiredTaskArguments) -and
        [string]$actions[0].WorkingDirectory -ceq $deployedRoot
    $triggerOk = $triggers.Count -eq 1 -and
        $triggers[0].CimClass.CimClassName -ceq 'MSFT_TaskLogonTrigger' -and
        [string]$triggers[0].UserId -ceq $currentUser -and
        $triggers[0].Enabled -eq $true
    $principalUserId = [string]$task.Principal.UserId
    $currentUserLeaf = $currentUser.Substring($currentUser.LastIndexOf('\') + 1)
    $principalIdentityOk =
        $principalUserId.Equals($currentUser, [StringComparison]::OrdinalIgnoreCase) -or
        $principalUserId.Equals($currentUserLeaf, [StringComparison]::OrdinalIgnoreCase)
    $principalOk = $principalIdentityOk -and
        [string]$task.Principal.LogonType -ceq 'Interactive' -and
        [string]$task.Principal.RunLevel -ceq 'Limited'
    $settingsOk = $task.Settings.Enabled -eq $true -and
        $task.Settings.Hidden -eq $true -and
        [string]$task.Settings.MultipleInstances -ceq 'IgnoreNew' -and
        [int]$task.Settings.RestartCount -eq 5 -and
        [string]$task.Settings.RestartInterval -ceq 'PT1M' -and
        [string]$task.Settings.ExecutionTimeLimit -ceq 'PT0S' -and
        $task.Settings.StartWhenAvailable -eq $true -and
        $task.Settings.DisallowStartIfOnBatteries -eq $false -and
        $task.Settings.StopIfGoingOnBatteries -eq $false
    return [pscustomobject][ordered]@{
        exists = $true
        owned = $owned
        configurationOk = $owned -and $actionOk -and $triggerOk -and $principalOk -and $settingsOk
        state = [string]$task.State
        currentUser = $currentUser
        actionOk = $actionOk
        triggerOk = $triggerOk
        principalOk = $principalOk
        settingsOk = $settingsOk
    }
}

function Register-DesiredTask {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction -Execute $pythonwPath -Argument (Get-DesiredTaskArguments) -WorkingDirectory $deployedRoot
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
    $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -Hidden `
        -MultipleInstances IgnoreNew `
        -RestartCount 5 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero)
    [void](Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description $taskDescription -Force)
}

function Assert-UniqueStateJsonProperties {
    param([Text.Json.JsonElement]$Element, [string]$Path = '$')

    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $seen.Add($property.Name)) { throw "watch state JSON 包含重复属性：$Path。" }
            Assert-UniqueStateJsonProperties -Element $property.Value -Path "$Path.$($property.Name)"
        }
    } elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        $index = 0
        foreach ($item in $Element.EnumerateArray()) {
            Assert-UniqueStateJsonProperties -Element $item -Path "$Path[$index]"
            $index++
        }
    }
}

function Assert-ExactStateJsonProperties {
    param([Text.Json.JsonElement]$Element, [string[]]$Expected, [string]$Path)

    if ($Element.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw "$Path 非 object。" }
    $actual = @($Element.EnumerateObject() | ForEach-Object Name)
    if ($actual.Count -ne $Expected.Count) { throw "$Path 属性集合漂移。" }
    $actualSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in $actual) { [void]$actualSet.Add($name) }
    if (@($Expected | Where-Object { -not $actualSet.Contains($_) }).Count -ne 0) { throw "$Path 属性集合漂移。" }
}

function Read-StrictStateString {
    param([Text.Json.JsonElement]$Element, [string]$Name, [string]$Path)
    $value = $Element.GetProperty($Name)
    if ($value.ValueKind -ne [Text.Json.JsonValueKind]::String) { throw "$Path.$Name 非 string。" }
    return $value.GetString()
}

function Read-StrictStateInteger {
    param([Text.Json.JsonElement]$Element, [string]$Name, [string]$Path, [switch]$Positive)
    $valueElement = $Element.GetProperty($Name)
    $value = [int64]0
    if ($valueElement.ValueKind -ne [Text.Json.JsonValueKind]::Number -or -not $valueElement.TryGetInt64([ref]$value)) {
        throw "$Path.$Name 非 JSON integer。"
    }
    if (($Positive -and $value -le 0) -or (-not $Positive -and $value -lt 0)) { throw "$Path.$Name 越界。" }
    return $value
}

function Read-StrictStateBoolean {
    param([Text.Json.JsonElement]$Element, [string]$Name, [string]$Path)
    $value = $Element.GetProperty($Name)
    if ($value.ValueKind -eq [Text.Json.JsonValueKind]::True) { return $true }
    if ($value.ValueKind -eq [Text.Json.JsonValueKind]::False) { return $false }
    throw "$Path.$Name 非 boolean。"
}

function Read-StrictStateUtcTimestamp {
    param([Text.Json.JsonElement]$Element, [string]$Name, [string]$Path)
    $text = Read-StrictStateString -Element $Element -Name $Name -Path $Path
    $parsed = [DateTimeOffset]::MinValue
    $style = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    if (-not [DateTimeOffset]::TryParseExact($text, "yyyy-MM-dd'T'HH:mm:ss.FFFFFFF'Z'", [Globalization.CultureInfo]::InvariantCulture, $style, [ref]$parsed)) {
        throw "$Path.$Name 不是精确 UTC Z 时间。"
    }
    return $text
}

function Read-StrictStateIdentity {
    param([Text.Json.JsonElement]$Element, [string]$Name, [string]$Path)
    $identityElement = $Element.GetProperty($Name)
    if ($identityElement.ValueKind -ne [Text.Json.JsonValueKind]::Array) { throw "$Path.$Name 非 array。" }
    $items = @($identityElement.EnumerateArray())
    if ($items.Count -ne 2) { throw "$Path.$Name 长度非法。" }
    $identity = [Collections.Generic.List[string]]::new()
    foreach ($item in $items) {
        if ($item.ValueKind -ne [Text.Json.JsonValueKind]::String) { throw "$Path.$Name 元素非 string。" }
        $value = $item.GetString()
        if ($value -cnotmatch '^[0-9a-f]+$') { throw "$Path.$Name 元素非法。" }
        $identity.Add($value)
    }
    return @($identity)
}

function Read-StrictSweepResults {
    param([Text.Json.JsonElement]$Element)
    if ($Element.ValueKind -ne [Text.Json.JsonValueKind]::Array) { throw '$.lastSweep.results 非 array。' }
    $results = [Collections.Generic.List[object]]::new()
    $index = 0
    foreach ($item in $Element.EnumerateArray()) {
        $path = "$.lastSweep.results[$index]"
        Assert-ExactStateJsonProperties -Element $item -Expected @('file', 'state', 'removedCount', 'beforeSha256', 'afterSha256', 'processedIdentity', 'processedSha256') -Path $path
        $file = Read-StrictStateString -Element $item -Name 'file' -Path $path
        $state = Read-StrictStateString -Element $item -Name 'state' -Path $path
        $beforeSha256 = Read-StrictStateString -Element $item -Name 'beforeSha256' -Path $path
        $afterSha256 = Read-StrictStateString -Element $item -Name 'afterSha256' -Path $path
        $processedSha256 = Read-StrictStateString -Element $item -Name 'processedSha256' -Path $path
        if ($file -cnotmatch '^[0-9a-f]{16}\.json$' -or $state -cnotin @('clean', 'modified') -or $beforeSha256 -cnotmatch '^[0-9a-f]{64}$' -or $afterSha256 -cnotmatch '^[0-9a-f]{64}$' -or $processedSha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw "$path 值非法。"
        }
        $results.Add([pscustomobject][ordered]@{
            file = $file
            state = $state
            removedCount = Read-StrictStateInteger -Element $item -Name 'removedCount' -Path $path
            beforeSha256 = $beforeSha256
            afterSha256 = $afterSha256
            processedIdentity = @(Read-StrictStateIdentity -Element $item -Name 'processedIdentity' -Path $path)
            processedSha256 = $processedSha256
        })
        $index++
    }
    return @($results)
}

function Read-StrictSweepBlocks {
    param([Text.Json.JsonElement]$Element)
    if ($Element.ValueKind -ne [Text.Json.JsonValueKind]::Array) { throw '$.lastSweep.blocked 非 array。' }
    $blocks = [Collections.Generic.List[object]]::new()
    $index = 0
    foreach ($item in $Element.EnumerateArray()) {
        $path = "$.lastSweep.blocked[$index]"
        Assert-ExactStateJsonProperties -Element $item -Expected @('file', 'code') -Path $path
        $fileElement = $item.GetProperty('file')
        if ($fileElement.ValueKind -eq [Text.Json.JsonValueKind]::Null) {
            $file = $null
        } elseif ($fileElement.ValueKind -eq [Text.Json.JsonValueKind]::String) {
            $file = $fileElement.GetString()
        } else {
            throw "$path.file 非 string/null。"
        }
        $code = Read-StrictStateString -Element $item -Name 'code' -Path $path
        if (($null -ne $file -and $file -cnotmatch '^(?:[0-9a-f]{16}\.json|\.codex-catalog-guard-.+)$') -or [string]::IsNullOrWhiteSpace($code)) { throw "$path 值非法。" }
        $blocks.Add([pscustomobject][ordered]@{ file = $file; code = $code })
        $index++
    }
    return @($blocks)
}

function ConvertFrom-StrictWatchStateJson {
    param([string]$Text)

    $options = [Text.Json.JsonDocumentOptions]::new()
    $options.AllowTrailingCommas = $false
    $options.CommentHandling = [Text.Json.JsonCommentHandling]::Disallow
    $options.MaxDepth = 64
    $document = [Text.Json.JsonDocument]::Parse($Text, $options)
    try {
        $root = $document.RootElement
        Assert-UniqueStateJsonProperties -Element $root
        Assert-ExactStateJsonProperties -Element $root -Expected @('schemaVersion', 'pid', 'startedUtc', 'heartbeatUtc', 'status', 'catalogRoot', 'metrics', 'lastSweep') -Path '$'
        $schemaVersion = Read-StrictStateInteger -Element $root -Name 'schemaVersion' -Path '$' -Positive
        if ($schemaVersion -ne 2) { throw '$.schemaVersion 非 2。' }
        $metricsElement = $root.GetProperty('metrics')
        Assert-ExactStateJsonProperties -Element $metricsElement -Expected @('metadataProbeCount', 'contentReadCount', 'rewriteCount') -Path '$.metrics'

        $lastSweepElement = $root.GetProperty('lastSweep')
        $lastSweep = $null
        if ($lastSweepElement.ValueKind -ne [Text.Json.JsonValueKind]::Null) {
            Assert-ExactStateJsonProperties -Element $lastSweepElement -Expected @('schemaVersion', 'ok', 'mode', 'completedAtUtc', 'scannedCount', 'changedCount', 'removedCount', 'blockedCount', 'pendingRetryCount', 'skippedUnchangedCount', 'results', 'blocked') -Path '$.lastSweep'
            $sweepSchemaVersion = Read-StrictStateInteger -Element $lastSweepElement -Name 'schemaVersion' -Path '$.lastSweep' -Positive
            if ($sweepSchemaVersion -ne 1) { throw '$.lastSweep.schemaVersion 非 1。' }
            $lastSweep = [pscustomobject][ordered]@{
                schemaVersion = 1
                ok = Read-StrictStateBoolean -Element $lastSweepElement -Name 'ok' -Path '$.lastSweep'
                mode = Read-StrictStateString -Element $lastSweepElement -Name 'mode' -Path '$.lastSweep'
                completedAtUtc = Read-StrictStateUtcTimestamp -Element $lastSweepElement -Name 'completedAtUtc' -Path '$.lastSweep'
                scannedCount = Read-StrictStateInteger -Element $lastSweepElement -Name 'scannedCount' -Path '$.lastSweep'
                changedCount = Read-StrictStateInteger -Element $lastSweepElement -Name 'changedCount' -Path '$.lastSweep'
                removedCount = Read-StrictStateInteger -Element $lastSweepElement -Name 'removedCount' -Path '$.lastSweep'
                blockedCount = Read-StrictStateInteger -Element $lastSweepElement -Name 'blockedCount' -Path '$.lastSweep'
                pendingRetryCount = Read-StrictStateInteger -Element $lastSweepElement -Name 'pendingRetryCount' -Path '$.lastSweep'
                skippedUnchangedCount = Read-StrictStateInteger -Element $lastSweepElement -Name 'skippedUnchangedCount' -Path '$.lastSweep'
                results = @(Read-StrictSweepResults -Element ($lastSweepElement.GetProperty('results')))
                blocked = @(Read-StrictSweepBlocks -Element ($lastSweepElement.GetProperty('blocked')))
            }
        }
        return [pscustomobject][ordered]@{
            schemaVersion = 2
            pid = Read-StrictStateInteger -Element $root -Name 'pid' -Path '$' -Positive
            startedUtc = Read-StrictStateUtcTimestamp -Element $root -Name 'startedUtc' -Path '$'
            heartbeatUtc = Read-StrictStateUtcTimestamp -Element $root -Name 'heartbeatUtc' -Path '$'
            status = Read-StrictStateString -Element $root -Name 'status' -Path '$'
            catalogRoot = Read-StrictStateString -Element $root -Name 'catalogRoot' -Path '$'
            metrics = [pscustomobject][ordered]@{
                metadataProbeCount = Read-StrictStateInteger -Element $metricsElement -Name 'metadataProbeCount' -Path '$.metrics'
                contentReadCount = Read-StrictStateInteger -Element $metricsElement -Name 'contentReadCount' -Path '$.metrics'
                rewriteCount = Read-StrictStateInteger -Element $metricsElement -Name 'rewriteCount' -Path '$.metrics'
            }
            lastSweep = $lastSweep
        }
    } finally {
        $document.Dispose()
    }
}

function Read-WatchState {
    param([string]$Path = $deployedStatePath)
    if (-not [IO.File]::Exists($Path)) { return $null }
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try {
            return (ConvertFrom-StrictWatchStateJson -Text ([IO.File]::ReadAllText($Path, $utf8Strict)))
        } catch {
            if ($attempt -eq 2) {
                if (
                    [Environment]::GetEnvironmentVariable($testModeEnvironment) -ceq '1' -and
                    [Environment]::GetEnvironmentVariable('CODEX_REMOTE_PLUGIN_CATALOG_GUARD_TEST_DIAGNOSTICS') -ceq '1'
                ) {
                    [Console]::Error.WriteLine($_.Exception.ToString())
                }
                return $null
            }
            Start-Sleep -Milliseconds 100
        }
    }
}

function Test-ObjectProperty {
    param([object]$Object, [string]$Name)
    return $null -ne $Object -and @($Object.PSObject.Properties.Name) -ccontains $Name
}

function Get-WatchStateHealth {
    param([object]$State, [string]$ExpectedCatalogRoot = $catalogRoot)

    $issues = [Collections.Generic.List[string]]::new()
    if ($null -eq $State) {
        $issues.Add('missing-or-unreadable')
        return [pscustomobject][ordered]@{ ok = $false; issueCount = 1; issues = @($issues); status = $null; pendingRetryCount = $null; lastSweepOk = $false; lastSweepFresh = $false; lastSweepCompletedAtUtc = $null }
    }
    $expectedStateProperties = @('schemaVersion', 'pid', 'startedUtc', 'heartbeatUtc', 'status', 'catalogRoot', 'metrics', 'lastSweep')
    if ((@($State.PSObject.Properties.Name) -join "`0") -cne ($expectedStateProperties -join "`0") -or -not (Test-ObjectProperty -Object $State -Name 'schemaVersion') -or [int]$State.schemaVersion -ne 2) {
        $issues.Add('schema-drift')
    }
    $status = if (Test-ObjectProperty -Object $State -Name 'status') { [string]$State.status } else { $null }
    if ($status -ceq 'retrying') { $issues.Add('retrying') }
    elseif ($status -cne 'running') { $issues.Add('status-not-running') }
    if (-not (Test-ObjectProperty -Object $State -Name 'catalogRoot') -or [string]$State.catalogRoot -cne $ExpectedCatalogRoot) {
        $issues.Add('catalog-root-drift')
    }
    if (-not (Test-ObjectProperty -Object $State -Name 'metrics')) {
        $issues.Add('metrics-missing')
    } else {
        $expectedMetricProperties = @('metadataProbeCount', 'contentReadCount', 'rewriteCount')
        if ((@($State.metrics.PSObject.Properties.Name) -join "`0") -cne ($expectedMetricProperties -join "`0")) { $issues.Add('metrics-schema-drift') }
    }

    $lastSweep = if (Test-ObjectProperty -Object $State -Name 'lastSweep') { $State.lastSweep } else { $null }
    $pendingRetryCount = $null
    $lastSweepOk = $false
    $lastSweepFresh = $false
    $lastSweepCompletedAtUtc = $null
    if ($null -eq $lastSweep) {
        $issues.Add('last-sweep-missing')
    } else {
        $expectedSweepProperties = @('schemaVersion', 'ok', 'mode', 'completedAtUtc', 'scannedCount', 'changedCount', 'removedCount', 'blockedCount', 'pendingRetryCount', 'skippedUnchangedCount', 'results', 'blocked')
        if ((@($lastSweep.PSObject.Properties.Name) -join "`0") -cne ($expectedSweepProperties -join "`0") -or [int]$lastSweep.schemaVersion -ne 1 -or [string]$lastSweep.mode -cne 'Sweep') {
            $issues.Add('last-sweep-schema-drift')
        }
        try { $pendingRetryCount = [int]$lastSweep.pendingRetryCount } catch { $pendingRetryCount = -1 }
        if ($pendingRetryCount -ne 0) { $issues.Add('pending-retry') }
        try {
            if ([int]$lastSweep.blockedCount -ne 0) { $issues.Add('blocked') }
        } catch { $issues.Add('blocked-count-invalid') }
        $lastSweepOk = $lastSweep.ok -eq $true
        if (-not $lastSweepOk) { $issues.Add('last-sweep-failed') }
        try {
            $completed = [DateTimeOffset]::Parse(
                [string]$lastSweep.completedAtUtc,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind).UtcDateTime
            $lastSweepCompletedAtUtc = $completed.ToString('o')
            $ageSeconds = ([DateTime]::UtcNow - $completed).TotalSeconds
            $lastSweepFresh = $ageSeconds -ge -5 -and $ageSeconds -le 45
        } catch {}
        if (-not $lastSweepFresh) { $issues.Add('last-sweep-stale') }
    }
    return [pscustomobject][ordered]@{
        ok = $issues.Count -eq 0
        issueCount = $issues.Count
        issues = @($issues)
        status = $status
        pendingRetryCount = $pendingRetryCount
        lastSweepOk = $lastSweepOk
        lastSweepFresh = $lastSweepFresh
        lastSweepCompletedAtUtc = $lastSweepCompletedAtUtc
    }
}

function Test-WatchMutexExists {
    $opened = $null
    try {
        if ([Threading.Mutex]::TryOpenExisting($watchMutexName, (New-CrossSessionCurrentUserOptions), [ref]$opened)) { return $true }
        return $false
    } finally {
        if ($null -ne $opened) { $opened.Dispose() }
    }
}

function Get-ProcessFacts {
    param([switch]$SkipDescendantAudit)
    $state = Read-WatchState
    $stateHealth = Get-WatchStateHealth -State $state
    if ($null -eq $state -or $state.PSObject.Properties.Name -notcontains 'pid') {
        return [pscustomobject][ordered]@{ ok = $false; running = $false; pid = $null; parentPid = $null; heartbeatFresh = $false; mutexExists = Test-WatchMutexExists; stateHealth = $stateHealth; mainWindowHandle = $null; parentWindowHandle = $null; conhostDescendantCount = $null }
    }
    $pidValue = [int]$state.pid
    $process = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $pidValue) -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        return [pscustomobject][ordered]@{ ok = $false; running = $false; pid = $pidValue; parentPid = $null; heartbeatFresh = $false; mutexExists = Test-WatchMutexExists; stateHealth = $stateHealth; mainWindowHandle = $null; parentWindowHandle = $null; conhostDescendantCount = $null }
    }
    $parent = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f ([int]$process.ParentProcessId)) -ErrorAction SilentlyContinue
    $heartbeatFresh = $false
    try {
        $heartbeat = [DateTimeOffset]::Parse(
            [string]$state.heartbeatUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind).UtcDateTime
        $heartbeatFresh = ([DateTime]::UtcNow - $heartbeat).TotalSeconds -le 45
    } catch {}
    $guardPath = Join-Path $deployedRoot 'CodexRemotePluginCatalogGuard.ps1'
    $launcherPath = Join-Path $deployedRoot 'hidden-console-launcher.py'
    $commandOk = [string]$process.ExecutablePath -ceq $pwshPath -and
        [string]$process.CommandLine -like "*${guardPath}*" -and
        [string]$process.CommandLine -like '*-Mode Watch*'
    $parentOk = $null -ne $parent -and [string]$parent.ExecutablePath -ceq $pythonwPath -and [string]$parent.CommandLine -like "*${launcherPath}*"
    $mainWindowHandle = $null
    $parentWindowHandle = $null
    try { $mainWindowHandle = [int64](Get-Process -Id $pidValue -ErrorAction Stop).MainWindowHandle } catch {}
    try { $parentWindowHandle = [int64](Get-Process -Id ([int]$process.ParentProcessId) -ErrorAction Stop).MainWindowHandle } catch {}
    if ($SkipDescendantAudit) {
        $mutexExists = Test-WatchMutexExists
        $ok = $commandOk -and $parentOk -and $heartbeatFresh -and $mutexExists -and $stateHealth.ok -and $mainWindowHandle -eq 0 -and $parentWindowHandle -eq 0
        return [pscustomobject][ordered]@{
            ok = $ok
            running = $true
            pid = $pidValue
            parentPid = [int]$process.ParentProcessId
            heartbeatFresh = $heartbeatFresh
            mutexExists = $mutexExists
            stateHealth = $stateHealth
            commandOk = $commandOk
            parentOk = $parentOk
            mainWindowHandle = $mainWindowHandle
            parentWindowHandle = $parentWindowHandle
            conhostDescendantCount = $null
            visibleWindowCount = $null
            descendantAuditSkipped = $true
        }
    }
    $allProcesses = @(Get-CimInstance Win32_Process -ErrorAction Stop | Select-Object ProcessId, ParentProcessId, Name)
    $descendantIds = [Collections.Generic.HashSet[int]]::new()
    [void]$descendantIds.Add($pidValue)
    if ($null -ne $parent) { [void]$descendantIds.Add([int]$parent.ProcessId) }
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($candidate in $allProcesses) {
            if ($descendantIds.Contains([int]$candidate.ParentProcessId) -and $descendantIds.Add([int]$candidate.ProcessId)) { $changed = $true }
        }
    }
    $conhostCount = @($allProcesses | Where-Object { $descendantIds.Contains([int]$_.ProcessId) -and [string]$_.Name -ieq 'conhost.exe' }).Count
    $visibleWindowCount = 0
    foreach ($descendantId in $descendantIds) {
        try {
            if ([int64](Get-Process -Id $descendantId -ErrorAction Stop).MainWindowHandle -ne 0) { $visibleWindowCount++ }
        } catch {}
    }
    $mutexExists = Test-WatchMutexExists
    $ok = $commandOk -and $parentOk -and $heartbeatFresh -and $mutexExists -and $stateHealth.ok -and $mainWindowHandle -eq 0 -and $parentWindowHandle -eq 0 -and $visibleWindowCount -eq 0
    return [pscustomobject][ordered]@{
        ok = $ok
        running = $true
        pid = $pidValue
        parentPid = [int]$process.ParentProcessId
        heartbeatFresh = $heartbeatFresh
        mutexExists = $mutexExists
        stateHealth = $stateHealth
        commandOk = $commandOk
        parentOk = $parentOk
        mainWindowHandle = $mainWindowHandle
        parentWindowHandle = $parentWindowHandle
        conhostDescendantCount = $conhostCount
        visibleWindowCount = $visibleWindowCount
        descendantAuditSkipped = $false
    }
}

function Get-CatalogFacts {
    param([string]$AuditFixtureRoot, [string]$AuditFixturePolicyPath)

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $pwshPath
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $runtimeSourcePath, '-Mode', 'Audit')) {
        [void]$start.ArgumentList.Add($argument)
    }
    if (-not [string]::IsNullOrWhiteSpace($AuditFixtureRoot)) {
        foreach ($argument in @('-FixtureRoot', $AuditFixtureRoot, '-PolicyPath', $AuditFixturePolicyPath)) { [void]$start.ArgumentList.Add($argument) }
        $start.Environment[$testModeEnvironment] = '1'
    }
    [void]$start.ArgumentList.Add('-Json')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'runtime Audit 无法启动。' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) { throw 'runtime Audit 超时。' }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        [void]$stderrTask.GetAwaiter().GetResult()
        $audit = if ([string]::IsNullOrWhiteSpace($stdout)) { $null } else { $stdout | ConvertFrom-Json -Depth 64 -DateKind String }
        if ($process.ExitCode -in @(0, 2) -and $null -ne $audit -and $audit.mode -ceq 'Audit') { return $audit }
        $code = 'runtime-audit-failure'
        if ($null -ne $audit -and $null -ne $audit.error -and [string]$audit.error.code -cmatch '^[a-z0-9-]+$') { $code = [string]$audit.error.code }
        return [pscustomobject][ordered]@{
            schemaVersion = 1
            ok = $false
            mode = 'Audit'
            completedAtUtc = [DateTime]::UtcNow.ToString('o')
            policyValid = $false
            policySchemaVersion = $null
            policySha256 = $null
            fileCount = 0
            pluginCount = 0
            targetCount = 0
            pairMismatchCount = 0
            files = @()
            blocked = @([pscustomobject][ordered]@{ file = $null; code = $code })
        }
    } catch {
        return [pscustomobject][ordered]@{
            schemaVersion = 1
            ok = $false
            mode = 'Audit'
            completedAtUtc = [DateTime]::UtcNow.ToString('o')
            policyValid = $false
            policySchemaVersion = $null
            policySha256 = $null
            fileCount = 0
            pluginCount = 0
            targetCount = 0
            pairMismatchCount = 0
            files = @()
            blocked = @([pscustomobject][ordered]@{ file = $null; code = 'runtime-audit-failure' })
        }
    } finally {
        if (-not $process.HasExited) { $process.Kill($true); [void]$process.WaitForExit(5000) }
        $process.Dispose()
    }
}

function Get-GuardStatus {
    $artifacts = Get-ArtifactFacts
    $task = Get-TaskFacts
    $process = Get-ProcessFacts
    $catalog = Get-CatalogFacts
    $drift = [Collections.Generic.List[string]]::new()
    foreach ($artifact in $artifacts) { if ($artifact.state -cne 'matching') { $drift.Add("artifact:$($artifact.name):$($artifact.state)") } }
    if (-not $task.exists) { $drift.Add('task:missing') }
    elseif (-not $task.owned) { $drift.Add('task:ownership-mismatch') }
    elseif (-not $task.configurationOk) { $drift.Add('task:configuration-drift') }
    elseif ($task.state -cne 'Running') { $drift.Add("task:state:$($task.state)") }
    if (-not $process.ok) { $drift.Add('process:unhealthy') }
    if ($null -ne $process.stateHealth) {
        foreach ($issue in @($process.stateHealth.issues)) { $drift.Add("watch-state:$issue") }
    }
    if ($catalog.policyValid -ne $true) { $drift.Add('policy:invalid') }
    if ($catalog.blocked.Count -ne 0) { $drift.Add('catalog:blocked') }
    if ($catalog.pairMismatchCount -ne 0) { $drift.Add('catalog:target-pair-mismatch') }
    if ($catalog.targetCount -ne 0) { $drift.Add("catalog:targets:$($catalog.targetCount)") }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        ok = $drift.Count -eq 0
        mode = 'Check'
        checkedAtUtc = [DateTime]::UtcNow.ToString('o')
        driftCount = $drift.Count
        drift = @($drift)
        artifacts = @($artifacts)
        task = $task
        process = $process
        catalog = $catalog
    }
}

function Assert-FixtureCheckArguments {
    $fixtureRequested =
        -not [string]::IsNullOrWhiteSpace($FixtureRoot) -or
        -not [string]::IsNullOrWhiteSpace($FixturePolicyPath) -or
        -not [string]::IsNullOrWhiteSpace($FixtureStatePath)
    if (-not $fixtureRequested) { return $false }
    if ($Mode -cne 'Check' -or [Environment]::GetEnvironmentVariable($testModeEnvironment) -cne '1') {
        throw 'fixture Check 参数仅允许受控测试进程。'
    }
    if ([string]::IsNullOrWhiteSpace($FixtureRoot) -or [string]::IsNullOrWhiteSpace($FixturePolicyPath)) {
        throw 'fixture Check 缺少固定 root 或 policy。'
    }
    $fullRoot = [IO.Path]::GetFullPath($FixtureRoot)
    $reportsRoot = Join-Path $projectRoot 'reports'
    $relative = [IO.Path]::GetRelativePath($reportsRoot, $fullRoot)
    $marker = Join-Path $fullRoot '.remote-plugin-catalog-guard-fixture'
    if ($relative -notmatch '^catalog-guard-tests-[0-9a-f]{32}\\\.codex$' -or -not [IO.File]::Exists($marker) -or [IO.File]::ReadAllText($marker, $utf8Strict) -cne "fixture-v1`n") {
        throw 'fixture Check root 不符合 allowlist。'
    }
    [void](Assert-DPathWithoutReparse -Path $fullRoot -RequireLeaf)
    if (-not [IO.Path]::GetFullPath($FixturePolicyPath).Equals((Join-Path $fullRoot 'policy.json'), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'fixture Check policy 不符合 allowlist。'
    }
    [void](Assert-DPathWithoutReparse -Path $FixturePolicyPath -RequireLeaf)
    if (-not [string]::IsNullOrWhiteSpace($FixtureStatePath)) {
        if (-not [IO.Path]::GetFullPath($FixtureStatePath).Equals((Join-Path $fullRoot 'state\state.json'), [StringComparison]::OrdinalIgnoreCase)) {
            throw 'fixture Check state 不符合 allowlist。'
        }
        [void](Assert-DPathWithoutReparse -Path $FixtureStatePath -RequireLeaf)
    }
    return $true
}

function Get-FixtureGuardStatus {
    $catalog = Get-CatalogFacts -AuditFixtureRoot $FixtureRoot -AuditFixturePolicyPath $FixturePolicyPath
    $stateHealth = $null
    $drift = [Collections.Generic.List[string]]::new()
    if ($catalog.policyValid -ne $true) { $drift.Add('policy:invalid') }
    if ($catalog.blocked.Count -ne 0) { $drift.Add('catalog:blocked') }
    if ($catalog.targetCount -ne 0) { $drift.Add("catalog:targets:$($catalog.targetCount)") }
    if (-not [string]::IsNullOrWhiteSpace($FixtureStatePath)) {
        $state = Read-WatchState -Path $FixtureStatePath
        $stateHealth = Get-WatchStateHealth -State $state -ExpectedCatalogRoot (Join-Path $FixtureRoot 'cache\remote_plugin_catalog')
        foreach ($issue in @($stateHealth.issues)) { $drift.Add("watch-state:$issue") }
    }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        ok = $drift.Count -eq 0
        mode = 'Check'
        fixture = $true
        checkedAtUtc = [DateTime]::UtcNow.ToString('o')
        driftCount = $drift.Count
        drift = @($drift)
        watcherState = $stateHealth
        catalog = $catalog
    }
}

function Stop-OwnedGuard {
    param([object]$TaskFacts, [object]$ProcessFacts, [Collections.Generic.List[string]]$Actions)
    if ($TaskFacts.exists -and -not $TaskFacts.owned) { throw '拒绝停止非本 guard 所有的同名任务。' }
    $stopSignaled = $false
    try {
        $stopEvent = [Threading.EventWaitHandle]::OpenExisting($stopEventName, (New-CrossSessionCurrentUserOptions))
        try { [void]$stopEvent.Set(); $Actions.Add('signal stop event'); $stopSignaled = $true } finally { $stopEvent.Dispose() }
    } catch [Threading.WaitHandleCannotBeOpenedException] {}
    if ($ProcessFacts.running -and $null -ne $ProcessFacts.pid) {
        for ($attempt = 0; $attempt -lt 50; $attempt++) {
            if ($null -eq (Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f ([int]$ProcessFacts.pid)) -ErrorAction SilentlyContinue)) { break }
            Start-Sleep -Milliseconds 100
        }
    }
    $currentTask = Get-TaskFacts
    if ($currentTask.exists -and $currentTask.state -ceq 'Running') {
        Stop-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop
        $Actions.Add('Stop-ScheduledTask')
    }
    if ($ProcessFacts.running -and $null -ne $ProcessFacts.pid) {
        $process = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f ([int]$ProcessFacts.pid)) -ErrorAction SilentlyContinue
        if ($null -ne $process) {
            $guardPath = Join-Path $deployedRoot 'CodexRemotePluginCatalogGuard.ps1'
            if ([string]$process.ExecutablePath -cne $pwshPath -or [string]$process.CommandLine -notlike "*${guardPath}*" -or [string]$process.CommandLine -notlike '*-Mode Watch*') { throw '拒绝终止 ownership 不匹配的进程。' }
            (Get-Process -Id ([int]$ProcessFacts.pid) -ErrorAction Stop).Kill($true)
            $Actions.Add($(if ($stopSignaled) { 'kill owned process after graceful-stop timeout' } else { 'kill owned stale process' }))
        }
    }
}

function Test-SingleInstance {
    $guardPath = Join-Path $deployedRoot 'CodexRemotePluginCatalogGuard.ps1'
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $pwshPath
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $guardPath, '-Mode', 'Watch')) { [void]$start.ArgumentList.Add($argument) }
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw '单实例探针无法启动。' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(15000)) { throw '单实例探针超时。' }
        [void]$stdoutTask.GetAwaiter().GetResult()
        [void]$stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 23) { throw '第二实例未被固定互斥锁拒绝。' }
        return $true
    } finally {
        if (-not $process.HasExited) { $process.Kill($true); [void]$process.WaitForExit(5000) }
        $process.Dispose()
    }
}

function Compare-CatalogNonTargets {
    param([object]$Before, [object]$After)
    $comparisons = [Collections.Generic.List[object]]::new()
    foreach ($beforeFile in @($Before.files)) {
        $afterFile = @($After.files | Where-Object file -ceq $beforeFile.file)
        if ($afterFile.Count -eq 1) {
            $comparisons.Add([pscustomobject][ordered]@{
                file = $beforeFile.file
                beforePluginCount = $beforeFile.pluginCount
                afterPluginCount = $afterFile[0].pluginCount
                beforeTargetCount = $beforeFile.targetCount
                afterTargetCount = $afterFile[0].targetCount
                nonTargetContentPreserved = $beforeFile.nonTargetContentSha256 -ceq $afterFile[0].nonTargetContentSha256
                beforeNonTargetContentSha256 = $beforeFile.nonTargetContentSha256
                afterNonTargetContentSha256 = $afterFile[0].nonTargetContentSha256
            })
        } else {
            $comparisons.Add([pscustomobject][ordered]@{ file = $beforeFile.file; nonTargetContentPreserved = $false; reason = 'file-replaced-or-removed-during-repair' })
        }
    }
    foreach ($afterFile in @($After.files | Where-Object { @($Before.files | Where-Object file -ceq $_.file).Count -eq 0 })) {
        $comparisons.Add([pscustomobject][ordered]@{ file = $afterFile.file; nonTargetContentPreserved = $null; reason = 'new-catalog-created-during-repair'; afterPluginCount = $afterFile.pluginCount })
    }
    return @($comparisons)
}

function Write-Evidence {
    param([object]$Evidence)
    [void](New-SafeDirectory -Path $evidenceRoot)
    $runId = "{0}-{1}" -f ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')), ([guid]::NewGuid().ToString('N'))
    $runRoot = Join-Path $evidenceRoot $runId
    [void](New-SafeDirectory -Path $runRoot)
    $path = Join-Path $runRoot 'evidence.json'
    [IO.File]::WriteAllText($path, (($Evidence | ConvertTo-Json -Depth 64) + "`n"), $utf8NoBom)
    return $path
}

function Get-ExistingRepairEvidencePath {
    if (-not [IO.Directory]::Exists($evidenceRoot)) { return $null }
    foreach ($directory in @(Get-ChildItem -LiteralPath $evidenceRoot -Directory -Force -ErrorAction Stop | Sort-Object Name -Descending)) {
        if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'evidence root 包含 reparse child。' }
        $candidate = Join-Path $directory.FullName 'evidence.json'
        if (-not [IO.File]::Exists($candidate)) { continue }
        try {
            $record = [IO.File]::ReadAllText($candidate, $utf8Strict) | ConvertFrom-Json -Depth 64 -DateKind String
            if ($record.operation -ceq 'Repair' -and $record.after.ok -eq $true) { return $candidate }
        } catch {}
    }
    return $null
}

function Invoke-Repair {
    $before = Get-GuardStatus
    if ($before.catalog.policyValid -ne $true) { throw 'source policy 或 runtime validator 非法，Repair 失败关闭。' }
    if (@($before.artifacts | Where-Object state -ceq 'unsafe').Count -ne 0) { throw '既有 deployed artifact 不安全，Repair 失败关闭。' }
    if ($before.task.exists -and -not $before.task.owned) { throw '同名计划任务 ownership 不匹配，Repair 失败关闭。' }
    if ($before.ok) {
        $existingEvidencePath = Get-ExistingRepairEvidencePath
        if ($null -eq $existingEvidencePath) {
            $singleInstanceOk = Test-SingleInstance
            $bootstrapEvidence = [ordered]@{
                schemaVersion = 1
                operation = 'Repair'
                timestampUtc = [DateTime]::UtcNow.ToString('o')
                changed = $true
                recoveredPartialDeployment = $true
                actions = @('record recovered partial deployment evidence')
                singleInstanceProbe = $singleInstanceOk
                before = $before
                after = $before
                catalogComparison = @(Compare-CatalogNonTargets -Before $before.catalog -After $before.catalog)
            }
            $evidencePath = Write-Evidence -Evidence $bootstrapEvidence
            return [pscustomobject][ordered]@{ schemaVersion = 1; ok = $true; mode = 'Repair'; changed = $true; recoveredPartialDeployment = $true; evidencePath = $evidencePath; singleInstanceProbe = $singleInstanceOk; status = $before }
        }
        return [pscustomobject][ordered]@{ schemaVersion = 1; ok = $true; mode = 'Repair'; changed = $false; evidencePath = $null; status = $before }
    }
    $actions = [Collections.Generic.List[string]]::new()
    $beforeCatalog = $before.catalog
    $artifactDrift = @($before.artifacts | Where-Object state -cne 'matching').Count -ne 0
    $taskDrift = -not $before.task.exists -or -not $before.task.configurationOk
    $processRestartRequired = -not $before.process.ok
    if (($artifactDrift -or $taskDrift -or $processRestartRequired) -and ($before.process.running -or ($before.task.exists -and $before.task.state -ceq 'Running'))) {
        Stop-OwnedGuard -TaskFacts $before.task -ProcessFacts $before.process -Actions $actions
    }
    if ($artifactDrift) {
        [void](New-SafeDirectory -Path $deployedRoot)
        foreach ($definition in $artifactDefinitions) {
            $fact = @($before.artifacts | Where-Object name -ceq $definition.name)[0]
            if ($fact.state -cne 'matching') {
                Publish-Artifact -Definition $definition -BeforeFact $fact
                $actions.Add("publish artifact $($definition.name)")
            }
        }
    }
    $taskAfterArtifacts = Get-TaskFacts
    if ($taskDrift) {
        if ($taskAfterArtifacts.exists) {
            if (-not $taskAfterArtifacts.owned) { throw '同名计划任务 ownership 在 Repair 期间漂移。' }
            Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false -ErrorAction Stop
            $actions.Add('Unregister-ScheduledTask owned drift')
        }
        Register-DesiredTask
        $actions.Add('Register-ScheduledTask at logon hidden')
    }
    $taskReady = Get-TaskFacts
    if (-not $taskReady.configurationOk) { throw '计划任务注册后仍不符合固定配置。' }
    if ($taskReady.state -cne 'Running') {
        Start-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop
        $actions.Add('Start-ScheduledTask')
    }
    $processReady = $false
    for ($attempt = 0; $attempt -lt 80; $attempt++) {
        $processFacts = Get-ProcessFacts -SkipDescendantAudit
        if ($processFacts.ok) { $processReady = $true; break }
        Start-Sleep -Milliseconds 250
    }
    if (-not $processReady) { throw 'guard 进程未在时限内达到健康态。' }
    $catalogReady = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $catalogFacts = Get-CatalogFacts
        if ($catalogFacts.ok) { $catalogReady = $true; break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $catalogReady) { throw 'live catalog 未在时限内收敛。' }
    $singleInstanceOk = Test-SingleInstance
    $after = Get-GuardStatus
    if (-not $after.ok) { throw "Repair 后仍有 drift：$($after.drift -join ',')" }
    $catalogComparison = Compare-CatalogNonTargets -Before $beforeCatalog -After $after.catalog
    if (@($catalogComparison | Where-Object { $_.nonTargetContentPreserved -eq $false }).Count -ne 0) { throw 'Repair 期间既有 catalog 的非目标内容未保持。' }
    $changed = $actions.Count -ne 0 -or $beforeCatalog.targetCount -ne $after.catalog.targetCount
    $evidence = [ordered]@{
        schemaVersion = 1
        operation = 'Repair'
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        changed = $changed
        actions = @($actions)
        singleInstanceProbe = $singleInstanceOk
        before = $before
        after = $after
        catalogComparison = @($catalogComparison)
    }
    $evidencePath = if ($changed) { Write-Evidence -Evidence $evidence } else { $null }
    return [pscustomobject][ordered]@{ schemaVersion = 1; ok = $true; mode = 'Repair'; changed = $changed; evidencePath = $evidencePath; singleInstanceProbe = $singleInstanceOk; catalogComparison = @($catalogComparison); status = $after }
}

function Invoke-Remove {
    $before = Get-GuardStatus
    if ($before.task.exists -and -not $before.task.owned) { throw '同名计划任务 ownership 不匹配，Remove 失败关闭。' }
    if (@($before.artifacts | Where-Object state -eq 'unsafe').Count -ne 0) { throw '既有 deployed artifact 不安全，Remove 失败关闭。' }
    $actions = [Collections.Generic.List[string]]::new()
    if ($before.process.running -or ($before.task.exists -and $before.task.state -ceq 'Running')) {
        Stop-OwnedGuard -TaskFacts $before.task -ProcessFacts $before.process -Actions $actions
    }
    $taskNow = Get-TaskFacts
    if ($taskNow.exists) {
        if (-not $taskNow.owned) { throw 'Remove 前任务 ownership 漂移。' }
        Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false -ErrorAction Stop
        $actions.Add('Unregister-ScheduledTask')
    }
    foreach ($definition in $artifactDefinitions) {
        $fact = @($before.artifacts | Where-Object name -ceq $definition.name)[0]
        if ($fact.state -eq 'matching' -or $fact.state -eq 'mismatch') {
            if (Remove-ManagedFile -Path $definition.target -ExpectedSha256 $fact.deployedSha256) { $actions.Add("remove artifact $($definition.name)") }
        }
    }
    if ([IO.File]::Exists($deployedStatePath)) {
        $stateSnapshot = Get-SafeFileSnapshot -Path $deployedStatePath
        if (Remove-ManagedFile -Path $deployedStatePath -ExpectedSha256 $stateSnapshot.sha256) { $actions.Add('remove guard state') }
    }
    if ([IO.Directory]::Exists($deployedStateRoot)) { [IO.Directory]::Delete($deployedStateRoot, $false) }
    if ([IO.Directory]::Exists($deployedRoot)) { [IO.Directory]::Delete($deployedRoot, $false) }
    $evidence = [ordered]@{
        schemaVersion = 1
        operation = 'Remove'
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        changed = $actions.Count -ne 0
        actions = @($actions)
        vendorCatalogRestored = $false
        catalogAfter = Get-CatalogFacts
    }
    $evidencePath = if ($actions.Count -ne 0) { Write-Evidence -Evidence $evidence } else { $null }
    return [pscustomobject][ordered]@{ schemaVersion = 1; ok = $true; mode = 'Remove'; changed = $actions.Count -ne 0; evidencePath = $evidencePath; vendorCatalogRestored = $false }
}

$fixtureCheck = Assert-FixtureCheckArguments
$handleSourcePath = Assert-DPathWithoutReparse -Path (Join-Path $projectRoot 'scripts\lib\CodexHookHandleBoundIO.cs') -RequireLeaf
if (-not ('CodexHookGovernance.VerifiedDirectoryChainGuard' -as [type])) { Add-Type -Path $handleSourcePath -ErrorAction Stop }
foreach ($runtimePath in @($pwshPath, $pythonwPath)) { [void](Get-SafeFileSnapshot -Path $runtimePath) }

$maintenanceCreated = $false
$maintenanceMutex = [Threading.Mutex]::new($false, $maintenanceMutexName, (New-CrossSessionCurrentUserOptions), [ref]$maintenanceCreated)
$maintenanceHeld = $false
$exitCode = 0
try {
    try { $maintenanceHeld = $maintenanceMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $maintenanceHeld = $true }
    if (-not $maintenanceHeld) { throw 'catalog guard maintenance mutex busy。' }
    switch ($Mode) {
        'Check' { $result = if ($fixtureCheck) { Get-FixtureGuardStatus } else { Get-GuardStatus }; if (-not $result.ok) { $exitCode = 2 } }
        'Repair' { $result = Invoke-Repair }
        'Remove' { $result = Invoke-Remove }
    }
    if ($Json) { $result | ConvertTo-Json -Compress -Depth 64 } else { $result }
} catch {
    $failure = [pscustomobject][ordered]@{ schemaVersion = 1; ok = $false; mode = $Mode; error = [ordered]@{ type = $_.Exception.GetType().Name; message = $_.Exception.Message } }
    if ($Json) { $failure | ConvertTo-Json -Compress -Depth 12 } else { [Console]::Error.WriteLine($_.Exception.Message) }
    $exitCode = 3
} finally {
    if ($maintenanceHeld) { try { [void]$maintenanceMutex.ReleaseMutex() } catch {} }
    $maintenanceMutex.Dispose()
}
exit $exitCode
