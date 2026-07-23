param(
    [string]$ProjectRoot = 'D:\Codex\projects\统一环境',
    [switch]$KeepOutputs
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptPath = Join-Path $ProjectRoot 'scripts\Invoke-RetiredProjectSnapshotSanitizer.ps1'
$pwshPath = 'D:\Codex\tools\PowerShell\7.6.4\pwsh.exe'
$retiredProject = 'codex-gsd-codex-c-skill'
$retiredRoot = "D:\Codex\projects\$retiredProject"
$safeRoot = 'D:\Codex\projects\统一环境'

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-SafeTestRoot {
    param([Parameter(Mandatory)][string]$Path)

    $reportsRoot = [IO.Path]::GetFullPath((Join-Path $ProjectRoot 'reports')).TrimEnd('\', '/')
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    Assert-True -Condition $fullPath.StartsWith("$reportsRoot\retired-project-snapshot-sanitizer-tests-", [StringComparison]::OrdinalIgnoreCase) -Message "测试目录必须位于 reports 专用前缀：$fullPath"
    Assert-True -Condition ([IO.Path]::GetPathRoot($fullPath) -eq 'D:\') -Message "测试目录必须位于 D 盘：$fullPath"

    $current = $fullPath
    while ($current.StartsWith($reportsRoot, [StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            Assert-True -Condition (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) -Message "测试路径祖先不得是 reparse point：$current"
        }
        if ($current.Equals($reportsRoot, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $parent = [IO.Directory]::GetParent($current)
        Assert-True -Condition ($null -ne $parent) -Message "无法解析测试目录父级：$current"
        $current = $parent.FullName.TrimEnd('\', '/')
    }
}

function Write-Utf8Text {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )

    $parent = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Get-ExpectedMixedTomlAfterSanitization {
    $content =
        '[fixture.before]' + "`r`n" +
        'sentinel = "mixed-before"' + "`n`n" +
        '[fixture.after]' + "`r`n" +
        'sentinel = "mixed-after"' + "`n"
    return $content
}

function New-GlobalStateDocument {
    param(
        [Parameter(Mandatory)][string]$RetiredRoot,
        [Parameter(Mandatory)][string]$SafeRoot,
        [switch]$MalformedWorkspaceRoots,
        [switch]$MalformedPromptHistory
    )

    $topHints = [ordered]@{
        'retired-top-thread' = $RetiredRoot
        'safe-top-thread' = $SafeRoot
    }
    $topOutputs = [ordered]@{
        'retired-top-thread' = 'D:\Codex\outputs\retired-top'
        'safe-top-thread' = 'D:\Codex\outputs\safe-top'
    }
    $nestedHints = [ordered]@{
        'retired-nested-thread' = $RetiredRoot
        'safe-nested-thread' = $SafeRoot
    }
    $nestedOutputs = [ordered]@{
        'retired-nested-thread' = 'D:\Codex\outputs\retired-nested'
        'safe-nested-thread' = 'D:\Codex\outputs\safe-nested'
    }
    $topPromptHistory = if ($MalformedPromptHistory) {
        $RetiredRoot
    } else {
        [ordered]@{
            'retired-top-thread' = @('must-remove-with-retired-thread', 'unrelated-entry-in-retired-thread')
            'safe-top-thread' = @('safe-top-prompt-must-survive')
            'unmapped-mixed-thread' = @("remove-direct-retired-reference:$RetiredRoot", 'safe-unmapped-prompt-must-survive')
        }
    }
    $nestedPromptHistory = [ordered]@{
        'retired-nested-thread' = @('must-remove-with-nested-retired-thread')
        'safe-nested-thread' = @('safe-nested-prompt-must-survive')
    }
    $atomState = [ordered]@{
        "sidebar-project-expanded-v1-codex:$RetiredRoot" = $true
        "sidebar-project-expanded-v1-codex:$SafeRoot" = $false
        'prompt-history' = $topPromptHistory
        nested = [ordered]@{
            'thread-workspace-root-hints' = $nestedHints
            'thread-projectless-output-directories' = $nestedOutputs
            'project-order' = @($RetiredRoot, $SafeRoot)
            'prompt-history' = $nestedPromptHistory
        }
    }
    $workspaceRoots = if ($MalformedWorkspaceRoots) { $RetiredRoot } else { @($RetiredRoot, $SafeRoot) }
    return [ordered]@{
        auth = [ordered]@{ token = 'fixture-auth-must-survive'; metadata = [ordered]@{ scope = 'fixture' } }
        'electron-saved-workspace-roots' = $workspaceRoots
        'project-order' = @($SafeRoot, $RetiredRoot)
        'active-workspace-roots' = @($RetiredRoot)
        'thread-workspace-root-hints' = $topHints
        'thread-projectless-output-directories' = $topOutputs
        'thread-descriptions-v1' = [ordered]@{
            'retired-title-thread' = "historical title $RetiredRoot"
            'safe-title-thread' = 'safe title must survive'
        }
        'electron-persisted-atom-state' = $atomState
        unrelated = [ordered]@{ root = $SafeRoot; values = @('a', 'b') }
    }
}

function Write-GlobalStateFixture {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$MalformedWorkspaceRoots,
        [switch]$MalformedPromptHistory
    )

    $document = New-GlobalStateDocument -RetiredRoot $retiredRoot -SafeRoot $safeRoot -MalformedWorkspaceRoots:$MalformedWorkspaceRoots -MalformedPromptHistory:$MalformedPromptHistory
    $json = [regex]::Replace(($document | ConvertTo-Json -Depth 30), '\r?\n', "`n")
    if (-not $json.EndsWith("`n", [StringComparison]::Ordinal)) {
        $json += "`n"
    }
    Write-Utf8Text -Path $Path -Content $json
}

function Get-RecursiveGlobalStateBakRelativePaths {
    return @(
        'backups_state\provider-sync\fixture\.codex-global-state.json.bak',
        'backups_state\remote-plugin-debug-20260630\fixture\.codex-global-state.json.bak',
        'backups_state\serena-dashboard-guard\fixture\.codex-global-state.json.bak',
        'backups_state\codex-state-policy\fixture\.codex-global-state.json.bak',
        'run-evidence\host-hook-remediation\fixture\.codex-global-state.json.bak',
        'run-evidence\codex-project-trust-repair\fixture\.codex-global-state.json.bak',
        'run-evidence\wss-enable\fixture\.codex-global-state.json.bak',
        'run-evidence\replicator\serena-runtime-repair-fixture\backup\.codex-global-state.json.bak',
        'run-evidence\replicator\remote-provider-fixture\backup\.codex-global-state.json.bak',
        'run-evidence\sidebar-recovery-fixture\.codex-global-state.json.bak'
    )
}

function New-FixtureHome {
    param(
        [Parameter(Mandatory)][string]$TestRoot,
        [Parameter(Mandatory)][string]$Label,
        [switch]$MalformedWorkspaceRoots,
        [switch]$MalformedPromptHistory
    )

    $fixtureHome = Join-Path $TestRoot "$Label\.codex"
    [IO.Directory]::CreateDirectory($fixtureHome) | Out-Null
    Write-Utf8Text -Path (Join-Path $fixtureHome '.retired-project-snapshot-sanitizer-fixture') -Content 'retired-project-snapshot-sanitizer-fixture-v1'

    $escapedRetired = 'D:\\Codex\\projects\\codex-gsd-codex-c-skill'
    $escapedRetiredWithUnicodeProjectId = 'D:\\Codex\\projects\\\u0063odex-gsd-codex-c-skill'
    $toml = @(
        '[fixture.before]'
        'sentinel = "must-survive"'
        'updated_at = "2026-07-16T19:31:15.348Z"'
        ''
        ('[projects."{0}"]' -f $escapedRetired)
        'trust_level = "trusted"'
        ''
        '[fixture.after]'
        'sentinel = "must-survive-after"'
        ''
    ) -join "`r`n"
    Write-Utf8Text -Path (Join-Path $fixtureHome '.config.toml.replace-backup.fixture') -Content $toml
    Write-Utf8Text -Path (Join-Path $fixtureHome 'config.toml') -Content $toml

    $serenaToml = @(
        '[mcp_servers.serena]'
        ('args = ["start-mcp-server", "--project", "{0}"]' -f $escapedRetired)
        ''
        '[fixture.survivor]'
        'sentinel = "must-survive-serena-neighbor"'
        ''
    ) -join "`n"
    $plainToml = @(
        '[projects."D:\\Users\\fixture\\unrelated-project"]'
        'trust_level = "trusted"'
        ''
        '[fixture.survivor]'
        'sentinel = "must-survive-plain-neighbor"'
        ''
    ) -join "`n"
    $mixedToml =
        '[fixture.before]' + "`r`n" +
        'sentinel = "mixed-before"' + "`n`n" +
        '[[fixture.retired-array]]' + "`r`n" +
        ('project = "{0}"' -f $escapedRetired) + "`n" +
        'retired_array_sentinel = "must-remove"' + "`r`n`n" +
        ('[projects."{0}"]' -f $escapedRetiredWithUnicodeProjectId) + "`n" +
        'retired_project_root_sentinel = "must-remove"' + "`r`n" +
        ('[projects."{0}".metadata]' -f $escapedRetiredWithUnicodeProjectId) + "`n" +
        'retired_project_descendant_table_sentinel = "must-remove"' + "`r`n" +
        ('[[projects."{0}".history]]' -f $escapedRetiredWithUnicodeProjectId) + "`n" +
        'retired_project_descendant_array_sentinel = "must-remove"' + "`r`n`n" +
        '[fixture.after]' + "`r`n" +
        'sentinel = "mixed-after"' + "`n"
    $tomlTargets = @(
        @{ relative = 'backups_state\provider-sync\20260713T145129356Z\config.toml'; content = $serenaToml },
        @{ relative = 'backups_state\remote-plugin-debug-20260630\config.toml'; content = $plainToml },
        @{ relative = 'backups_state\remote-plugin-debug-20260630\config.toml.before-openai-bundled-marketplace'; content = $plainToml },
        @{ relative = 'run-evidence\host-hook-remediation\20260714T204345.474Z-fixture\config.toml'; content = $plainToml },
        @{ relative = 'run-evidence\codex-project-trust-repair\fixture\config.toml'; content = $plainToml },
        @{ relative = 'run-evidence\codex-project-trust-repair\fixture\config.toml.pre-canary'; content = $plainToml },
        @{ relative = 'run-evidence\wss-enable\fixture\config.toml.before'; content = $plainToml },
        @{ relative = 'run-evidence\replicator\serena-runtime-repair-fixture\backup\config.toml'; content = $plainToml },
        @{ relative = 'run-evidence\replicator\serena-runtime-repair-mixed-fixture\backup\config-before-serena-repair\config.toml'; content = $mixedToml },
        @{ relative = 'run-evidence\replicator\remote-provider-fixture\backup\config.toml'; content = $plainToml }
    )
    foreach ($target in $tomlTargets) {
        Write-Utf8Text -Path (Join-Path $fixtureHome $target.relative) -Content $target.content
    }
    $unrelatedToml = @(
        '[projects."D:\\Codex\\projects\\codex-gsd-codex-c-skill"]'
        'trust_level = "trusted"'
        ''
    ) -join [Environment]::NewLine
    Write-Utf8Text -Path (Join-Path $fixtureHome 'run-evidence\unrelated\config.toml.pre-canary') -Content $unrelatedToml

    $yaml = @(
        'projects:'
        "- $retiredRoot"
        "- $safeRoot"
        'other: must-survive'
        ''
    ) -join "`n"
    Write-Utf8Text -Path (Join-Path $fixtureHome 'backups_state\serena-dashboard-guard\fixture\serena_config.yml') -Content $yaml
    Write-Utf8Text -Path (Join-Path $fixtureHome 'run-evidence\replicator\serena-runtime-repair-fixture\backup\serena_config.yml') -Content $yaml

    Write-GlobalStateFixture -Path (Join-Path $fixtureHome '.codex-global-state.json') -MalformedWorkspaceRoots:$MalformedWorkspaceRoots -MalformedPromptHistory:$MalformedPromptHistory
    Write-GlobalStateFixture -Path (Join-Path $fixtureHome '.codex-global-state.json.bak') -MalformedWorkspaceRoots:$MalformedWorkspaceRoots -MalformedPromptHistory:$MalformedPromptHistory
    foreach ($runtime in @('login_runtime', 'refresh_runtime')) {
        Write-GlobalStateFixture -Path (Join-Path $fixtureHome "account_backup\windows\$runtime\.codex-global-state.json") -MalformedWorkspaceRoots:$MalformedWorkspaceRoots -MalformedPromptHistory:$MalformedPromptHistory
    }
    Write-GlobalStateFixture -Path (Join-Path $fixtureHome 'backups_state\codex-state-policy\fixture\.codex-global-state.json') -MalformedWorkspaceRoots:$MalformedWorkspaceRoots -MalformedPromptHistory:$MalformedPromptHistory
    Write-GlobalStateFixture -Path (Join-Path $fixtureHome 'run-evidence\sidebar-recovery-fixture\.codex-global-state.json') -MalformedWorkspaceRoots:$MalformedWorkspaceRoots -MalformedPromptHistory:$MalformedPromptHistory
    Write-GlobalStateFixture -Path (Join-Path $fixtureHome 'run-evidence\sidebar-recovery-fixture\global-state.restore-source.json') -MalformedWorkspaceRoots:$MalformedWorkspaceRoots -MalformedPromptHistory:$MalformedPromptHistory
    foreach ($relativePath in @(Get-RecursiveGlobalStateBakRelativePaths)) {
        Write-GlobalStateFixture -Path (Join-Path $fixtureHome $relativePath) -MalformedWorkspaceRoots:$MalformedWorkspaceRoots -MalformedPromptHistory:$MalformedPromptHistory
    }
    return $fixtureHome
}

function Get-FileFingerprint {
    param([Parameter(Mandatory)][string]$Root)

    $entries = [Collections.Generic.List[string]]::new()
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($Root)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force)) {
            Assert-True -Condition (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) -Message "普通 fixture fingerprint 不得经过 reparse point：$($item.FullName)"
            if ($item.PSIsContainer) {
                $pending.Push($item.FullName)
            } else {
                $relative = [IO.Path]::GetRelativePath($Root, $item.FullName)
                $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
                $entries.Add("$relative|$hash")
            }
        }
    }
    return @($entries | Sort-Object) -join "`n"
}

function Start-PayloadBackupWatcher {
    param([Parameter(Mandatory)][string]$Root)

    $watcher = [IO.FileSystemWatcher]::new($Root)
    $watcher.IncludeSubdirectories = $true
    $watcher.NotifyFilter = [IO.NotifyFilters]::FileName
    $prefix = "retired-project-snapshot-sanitizer-$([guid]::NewGuid().ToString('N'))"
    $sourceIdentifiers = [Collections.Generic.List[string]]::new()
    foreach ($eventName in @('Created', 'Renamed')) {
        $sourceIdentifier = "$prefix-$eventName"
        Register-ObjectEvent -InputObject $watcher -EventName $eventName -SourceIdentifier $sourceIdentifier | Out-Null
        $sourceIdentifiers.Add($sourceIdentifier)
    }
    $watcher.EnableRaisingEvents = $true
    return [pscustomobject]@{
        watcher = $watcher
        sourceIdentifiers = @($sourceIdentifiers.ToArray())
    }
}

function Get-PayloadBackupEvents {
    param([Parameter(Mandatory)][psobject]$Watcher)

    # Wait once so FileSystemWatcher delivery from the child sanitizer process reaches
    # this runspace before the queue is inspected.
    $null = Wait-Event -Timeout 1
    $events = [Collections.Generic.List[string]]::new()
    foreach ($sourceIdentifier in $Watcher.sourceIdentifiers) {
        foreach ($queuedEvent in @(Get-Event -SourceIdentifier $sourceIdentifier -ErrorAction SilentlyContinue)) {
            try {
                $eventArgs = $queuedEvent.SourceEventArgs
                $names = [Collections.Generic.List[string]]::new()
                $names.Add([string]$eventArgs.Name)
                if ($eventArgs -is [IO.RenamedEventArgs]) {
                    $names.Add([string]$eventArgs.OldName)
                }
                foreach ($name in $names) {
                    if ($name -like '*.retired-project-snapshot-sanitizer-*.bak') {
                        $events.Add("$($eventArgs.ChangeType):$name")
                    }
                }
            } finally {
                Remove-Event -EventIdentifier $queuedEvent.EventIdentifier -ErrorAction SilentlyContinue
            }
        }
    }
    return @($events.ToArray())
}

function Stop-PayloadBackupWatcher {
    param([Parameter(Mandatory)][psobject]$Watcher)

    foreach ($sourceIdentifier in $Watcher.sourceIdentifiers) {
        Unregister-Event -SourceIdentifier $sourceIdentifier -ErrorAction SilentlyContinue
        foreach ($queuedEvent in @(Get-Event -SourceIdentifier $sourceIdentifier -ErrorAction SilentlyContinue)) {
            Remove-Event -EventIdentifier $queuedEvent.EventIdentifier -ErrorAction SilentlyContinue
        }
    }
    $Watcher.watcher.Dispose()
}

function Assert-NoSanitizerTemporaryPayloadFiles {
    param([Parameter(Mandatory)][string]$Root)

    $temporaryPayloadFiles = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Where-Object {
        $_.Name -like '*.retired-project-snapshot-sanitizer-*.tmp' -or
        $_.Name -like '*.retired-project-snapshot-sanitizer-*.bak'
    })
    Assert-True -Condition ($temporaryPayloadFiles.Count -eq 0) -Message 'Apply 留下了临时 payload 文件。'
}

function Invoke-Sanitizer {
    param(
        [Parameter(Mandatory)][string]$FixtureRoot,
        [ValidateSet('Audit', 'Apply')][string]$Mode = 'Audit',
        [string[]]$ConfirmRetiredProject = @(),
        [bool]$ColdMaintenance = $true
    )

    $callArgs = @('-NoProfile', '-File', $scriptPath, '-Mode', $Mode, '-FixtureRoot', $FixtureRoot, '-Json')
    if ($ColdMaintenance) {
        $callArgs += '-ColdMaintenance'
    }
    foreach ($value in $ConfirmRetiredProject) {
        $callArgs += '-ConfirmRetiredProject'
        $callArgs += $value
    }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $pwshPath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $callArgs) { [void]$start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        Assert-True -Condition $process.Start() -Message 'sanitizer 子进程无法启动。'
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        Assert-True -Condition ($process.WaitForExit(120000)) -Message 'sanitizer 子进程超时。'
        $exitCode = $process.ExitCode
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
    } finally {
        if (-not $process.HasExited) { try { $process.Kill($true) } catch {} }
        $process.Dispose()
    }
    $raw = @($stdout,$stderr | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n"
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw 'sanitizer 未输出 JSON 摘要。'
    }
    try {
        $parsed = $raw | ConvertFrom-Json -AsHashtable -NoEnumerate
    } catch {
        throw "sanitizer 输出不是 JSON：$raw"
    }
    return [pscustomobject]@{ exitCode = $exitCode; result = $parsed; raw = $raw }
}

function Assert-NoRetiredMarker {
    param([Parameter(Mandatory)][string]$Path)

    $content = [IO.File]::ReadAllText($Path)
    Assert-True -Condition (-not $content.Contains($retiredProject, [StringComparison]::OrdinalIgnoreCase)) -Message "退休 marker 仍存在：$Path"
}

function Assert-GlobalStateSanitized {
    param([Parameter(Mandatory)][string]$Path)

    $document = [IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable -NoEnumerate
    Assert-True -Condition ($document.auth.token -ceq 'fixture-auth-must-survive') -Message "auth sentinel 被错误改变：$Path"
    foreach ($field in @('electron-saved-workspace-roots', 'project-order', 'active-workspace-roots')) {
        Assert-True -Condition (@($document[$field] | Where-Object { $_ -ceq $safeRoot }).Count -ge 1 -or $field -ceq 'active-workspace-roots') -Message "保留 workspace root 丢失：$Path / $field"
        Assert-True -Condition (@($document[$field] | Where-Object { $_ -ceq $retiredRoot }).Count -eq 0) -Message "退休 workspace root 仍存在：$Path / $field"
    }
    Assert-True -Condition (-not $document['thread-workspace-root-hints'].Contains('retired-top-thread')) -Message "顶层 retired thread hint 未移除：$Path"
    Assert-True -Condition (-not $document['thread-projectless-output-directories'].Contains('retired-top-thread')) -Message "顶层关联 output 未移除：$Path"
    Assert-True -Condition ($document['thread-workspace-root-hints'].Contains('safe-top-thread')) -Message "顶层 safe thread hint 被误删：$Path"
    Assert-True -Condition ($document['thread-projectless-output-directories'].Contains('safe-top-thread')) -Message "顶层 safe output 被误删：$Path"
    $atom = $document['electron-persisted-atom-state']
    Assert-True -Condition (-not $atom.Contains("sidebar-project-expanded-v1-codex:$retiredRoot")) -Message "sidebar retired state 未移除：$Path"
    Assert-True -Condition ($atom.Contains("sidebar-project-expanded-v1-codex:$safeRoot")) -Message "sidebar safe state 被误删：$Path"
    $promptHistory = $atom['prompt-history']
    Assert-True -Condition ($promptHistory.Contains('retired-top-thread')) -Message "用户顶层 prompt history 被误删：$Path"
    Assert-True -Condition (@($promptHistory['retired-top-thread']) -contains 'must-remove-with-retired-thread') -Message "用户退休项目 prompt 被误删：$Path"
    Assert-True -Condition ($promptHistory.Contains('safe-top-thread')) -Message "safe 顶层 prompt history 被误删：$Path"
    Assert-True -Condition (@($promptHistory['safe-top-thread']) -contains 'safe-top-prompt-must-survive') -Message "safe 顶层 prompt 被误删：$Path"
    Assert-True -Condition ($promptHistory.Contains('unmapped-mixed-thread')) -Message "非关联 prompt history map 被误删：$Path"
    Assert-True -Condition (@($promptHistory['unmapped-mixed-thread']) -contains 'safe-unmapped-prompt-must-survive') -Message "非关联 prompt history 的保留项被误删：$Path"
    Assert-True -Condition (@($promptHistory['unmapped-mixed-thread'] | Where-Object { $_ -like "*$retiredProject*" }).Count -gt 0) -Message "用户直接提到退休项目的 prompt 被误删：$Path"
    $nested = $atom.nested
    Assert-True -Condition (-not $nested['thread-workspace-root-hints'].Contains('retired-nested-thread')) -Message "嵌套 retired thread hint 未移除：$Path"
    Assert-True -Condition (-not $nested['thread-projectless-output-directories'].Contains('retired-nested-thread')) -Message "嵌套关联 output 未移除：$Path"
    Assert-True -Condition ($nested['thread-workspace-root-hints'].Contains('safe-nested-thread')) -Message "嵌套 safe thread hint 被误删：$Path"
    Assert-True -Condition ($nested['thread-projectless-output-directories'].Contains('safe-nested-thread')) -Message "嵌套 safe output 被误删：$Path"
    $nestedPromptHistory = $nested['prompt-history']
    Assert-True -Condition ($nestedPromptHistory.Contains('retired-nested-thread')) -Message "用户嵌套 prompt history 被误删：$Path"
    Assert-True -Condition (@($nestedPromptHistory['retired-nested-thread']) -contains 'must-remove-with-nested-retired-thread') -Message "用户嵌套退休项目 prompt 被误删：$Path"
    Assert-True -Condition ($nestedPromptHistory.Contains('safe-nested-thread')) -Message "safe 嵌套 prompt history 被误删：$Path"
    Assert-True -Condition (@($nestedPromptHistory['safe-nested-thread']) -contains 'safe-nested-prompt-must-survive') -Message "safe 嵌套 prompt 被误删：$Path"
    Assert-True -Condition ($document['thread-descriptions-v1'].Contains('retired-title-thread')) -Message "用户线程标题被误删：$Path"
    Assert-True -Condition ($document['thread-descriptions-v1']['retired-title-thread'].Contains($retiredProject, [StringComparison]::OrdinalIgnoreCase)) -Message "用户线程标题中的退休项目文字被误删：$Path"
}

function New-Junction {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Target
    )

    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [IO.Directory]::CreateDirectory($Target) | Out-Null
    New-Item -ItemType Junction -Path $Path -Target $Target -ErrorAction Stop | Out-Null
}

function Remove-GeneratedTestTree {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    Assert-SafeTestRoot -Path $Path
    $reparseItems = @(Get-ChildItem -LiteralPath $Path -Recurse -Force | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 } | Sort-Object FullName -Descending)
    foreach ($item in $reparseItems) {
        Remove-Item -LiteralPath $item.FullName -Force
    }
    $remainingReparse = @(Get-ChildItem -LiteralPath $Path -Recurse -Force | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
    Assert-True -Condition ($remainingReparse.Count -eq 0) -Message 'fixture 清理前仍有 reparse point。'
    Remove-Item -LiteralPath $Path -Recurse -Force
}

$testRoot = Join-Path $ProjectRoot ("reports\retired-project-snapshot-sanitizer-tests-$([guid]::NewGuid().ToString('N'))")
$payloadBackupWatchers = [Collections.Generic.List[object]]::new()
try {
    Assert-True -Condition (Test-Path -LiteralPath $scriptPath -PathType Leaf) -Message '缺少 sanitizer 脚本。'
    Assert-True -Condition (Test-Path -LiteralPath $pwshPath -PathType Leaf) -Message '缺少固定 PowerShell runtime。'
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null
    Assert-SafeTestRoot -Path $testRoot

    $validHome = New-FixtureHome -TestRoot $testRoot -Label valid
    $validPayloadBackupWatcher = Start-PayloadBackupWatcher -Root $validHome
    $payloadBackupWatchers.Add($validPayloadBackupWatcher)
    $beforeAudit = Get-FileFingerprint -Root $validHome
    $audit = Invoke-Sanitizer -FixtureRoot $validHome
    Assert-True -Condition ($audit.exitCode -eq 1) -Message '发现退休快照的 Audit 必须以非零退出。'
    Assert-True -Condition (-not [bool]$audit.result.ok -and [int]$audit.result.findingCount -ge 18) -Message 'Audit 未枚举预期的快照和 global-state target。'
    Assert-True -Condition (@($audit.result.findings | Where-Object { $_.path -ceq (Join-Path $validHome 'config.toml') }).Count -eq 0) -Message 'live config.toml 不得成为 sanitizer target。'
    Assert-True -Condition ((Get-FileFingerprint -Root $validHome) -ceq $beforeAudit) -Message 'Audit 修改了 fixture。'
    Assert-True -Condition (@(Get-PayloadBackupEvents -Watcher $validPayloadBackupWatcher).Count -eq 0) -Message 'Audit 不得创建旧内容 .bak payload。'
    Assert-NoSanitizerTemporaryPayloadFiles -Root $validHome

    $missingConfirmation = Invoke-Sanitizer -FixtureRoot $validHome -Mode Apply
    Assert-True -Condition ($missingConfirmation.exitCode -eq 1 -and -not [bool]$missingConfirmation.result.ok) -Message '缺少显式确认的 Apply 必须拒绝。'
    Assert-True -Condition ((Get-FileFingerprint -Root $validHome) -ceq $beforeAudit) -Message '缺少确认的 Apply 修改了 fixture。'
    Assert-True -Condition (@(Get-PayloadBackupEvents -Watcher $validPayloadBackupWatcher).Count -eq 0) -Message '被拒绝的 Apply 不得创建旧内容 .bak payload。'
    Assert-NoSanitizerTemporaryPayloadFiles -Root $validHome

    $missingColdMaintenance = Invoke-Sanitizer -FixtureRoot $validHome -Mode Apply -ConfirmRetiredProject $retiredProject -ColdMaintenance:$false
    Assert-True -Condition ($missingColdMaintenance.exitCode -eq 1 -and -not [bool]$missingColdMaintenance.result.ok) -Message '缺少 cold-maintenance 显式确认的 Apply 必须拒绝。'
    Assert-True -Condition ((Get-FileFingerprint -Root $validHome) -ceq $beforeAudit) -Message '缺少 cold-maintenance 的 Apply 修改了 fixture。'
    Assert-True -Condition (@(Get-PayloadBackupEvents -Watcher $validPayloadBackupWatcher).Count -eq 0) -Message '被拒绝的 cold-maintenance Apply 不得创建旧内容 .bak payload。'
    Assert-NoSanitizerTemporaryPayloadFiles -Root $validHome

    $applied = Invoke-Sanitizer -FixtureRoot $validHome -Mode Apply -ConfirmRetiredProject $retiredProject
    Assert-True -Condition ($applied.exitCode -eq 0 -and [bool]$applied.result.ok -and [bool]$applied.result.changed) -Message "受控 Apply 未成功：$($applied.raw)"
    Assert-True -Condition (@(Get-PayloadBackupEvents -Watcher $validPayloadBackupWatcher).Count -eq 0) -Message '成功的 Apply 不得创建旧内容 .bak payload。'
    Assert-NoSanitizerTemporaryPayloadFiles -Root $validHome
    Assert-True -Condition ([IO.File]::ReadAllText((Join-Path $validHome 'config.toml')).Contains($retiredProject, [StringComparison]::OrdinalIgnoreCase)) -Message 'sanitizer 错误修改了 live config.toml fixture。'
    Assert-True -Condition ([IO.File]::ReadAllText((Join-Path $validHome '.config.toml.replace-backup.fixture')).Contains('updated_at = "2026-07-16T19:31:15.348Z"', [StringComparison]::Ordinal)) -Message '普通单行 TOML ISO timestamp 被错误解析或改写。'

    $recursiveGlobalStateBakPaths = @(Get-RecursiveGlobalStateBakRelativePaths | ForEach-Object { Join-Path $validHome $_ })
    foreach ($stateBakPath in $recursiveGlobalStateBakPaths) {
        Assert-True -Condition (@($audit.result.findings | Where-Object { $_.path -ceq $stateBakPath -and $_.kind -ceq 'json' }).Count -eq 1) -Message "受控递归根的 global-state .bak 未进入 sanitizer target：$stateBakPath"
    }

    $sanitizedTomlPaths = @($audit.result.findings | Where-Object { $_.kind -ceq 'toml' } | ForEach-Object { [string]$_.path })
    foreach ($tomlPath in $sanitizedTomlPaths) {
        Assert-NoRetiredMarker -Path $tomlPath
    }
    Assert-True -Condition ([IO.File]::ReadAllText((Join-Path $validHome 'run-evidence\unrelated\config.toml.pre-canary')).Contains($retiredProject, [StringComparison]::OrdinalIgnoreCase)) -Message 'sanitizer 扩大到未受控 evidence 树。'
    $providerToml = [IO.File]::ReadAllText((Join-Path $validHome 'backups_state\provider-sync\20260713T145129356Z\config.toml'))
    Assert-True -Condition (-not $providerToml.Contains('[mcp_servers.serena]', [StringComparison]::Ordinal)) -Message '含旧 --project 的 Serena table 未删除。'
    Assert-True -Condition ($providerToml.Contains('must-survive-serena-neighbor', [StringComparison]::Ordinal)) -Message '删除 Serena table 时误伤相邻 TOML table。'
    $mixedTomlPath = Join-Path $validHome 'run-evidence\replicator\serena-runtime-repair-mixed-fixture\backup\config-before-serena-repair\config.toml'
    $expectedMixedToml = Get-ExpectedMixedTomlAfterSanitization
    Assert-NoRetiredMarker -Path $mixedTomlPath
    Assert-True -Condition ([Convert]::ToHexString([IO.File]::ReadAllBytes($mixedTomlPath)) -ceq [Convert]::ToHexString([Text.UTF8Encoding]::new($false).GetBytes($expectedMixedToml))) -Message '混合 CRLF/LF TOML 的未删除字节布局未被保留。'
    $mixedTomlContent = [IO.File]::ReadAllText($mixedTomlPath)
    foreach ($marker in @(
        'retired_array_sentinel',
        'retired_project_root_sentinel',
        'retired_project_descendant_table_sentinel',
        'retired_project_descendant_array_sentinel'
    )) {
        Assert-True -Condition (-not $mixedTomlContent.Contains($marker, [StringComparison]::Ordinal)) -Message "混合 TOML 未删除预期 array/project descendant block：$marker"
    }
    foreach ($yamlPath in @(Get-ChildItem -LiteralPath $validHome -Recurse -File -Force -Filter 'serena_config.yml')) {
        Assert-NoRetiredMarker -Path $yamlPath.FullName
        Assert-True -Condition ([IO.File]::ReadAllText($yamlPath.FullName).Contains($safeRoot, [StringComparison]::Ordinal)) -Message "YAML 清理误删保留 project：$($yamlPath.FullName)"
    }
    foreach ($statePath in @(
        (Join-Path $validHome '.codex-global-state.json'),
        (Join-Path $validHome '.codex-global-state.json.bak'),
        (Join-Path $validHome 'account_backup\windows\login_runtime\.codex-global-state.json'),
        (Join-Path $validHome 'account_backup\windows\refresh_runtime\.codex-global-state.json'),
        (Join-Path $validHome 'backups_state\codex-state-policy\fixture\.codex-global-state.json'),
        (Join-Path $validHome 'run-evidence\sidebar-recovery-fixture\.codex-global-state.json'),
        (Join-Path $validHome 'run-evidence\sidebar-recovery-fixture\global-state.restore-source.json')
    ) + $recursiveGlobalStateBakPaths) {
        Assert-GlobalStateSanitized -Path $statePath
    }

    $postApplyAudit = Invoke-Sanitizer -FixtureRoot $validHome
    Assert-True -Condition ($postApplyAudit.exitCode -eq 0 -and [bool]$postApplyAudit.result.ok -and [int]$postApplyAudit.result.findingCount -eq 0) -Message 'Apply 后 Audit 仍有退休引用。'
    Stop-PayloadBackupWatcher -Watcher $validPayloadBackupWatcher
    [void]$payloadBackupWatchers.Remove($validPayloadBackupWatcher)

    $ambiguousHome = New-FixtureHome -TestRoot $testRoot -Label ambiguous-same-name
    $ambiguousTomlPath = Join-Path $ambiguousHome '.config.toml.replace-backup.fixture'
    $ambiguousToml = @(
        '[projects."D:\\Users\\fixture\\codex-gsd-codex-c-skill"]'
        'trust_level = "trusted"'
        ''
        '[fixture.notes]'
        'message = "historical codex-gsd-codex-c-skill text must survive"'
        ''
    ) -join [Environment]::NewLine
    Write-Utf8Text -Path $ambiguousTomlPath -Content $ambiguousToml
    $ambiguousYamlPath = Join-Path $ambiguousHome 'backups_state\serena-dashboard-guard\fixture\serena_config.yml'
    $ambiguousYaml = @(
        'projects:'
        '- D:\Users\fixture\codex-gsd-codex-c-skill'
        "- $safeRoot"
        ''
    ) -join [Environment]::NewLine
    Write-Utf8Text -Path $ambiguousYamlPath -Content $ambiguousYaml
    $ambiguousJsonPath = Join-Path $ambiguousHome '.codex-global-state.json'
    $ambiguousDocument = [IO.File]::ReadAllText($ambiguousJsonPath) | ConvertFrom-Json -AsHashtable -NoEnumerate
    $ambiguousDocument['electron-saved-workspace-roots'] = @($ambiguousDocument['electron-saved-workspace-roots']) + 'D:\Users\fixture\codex-gsd-codex-c-skill'
    Write-Utf8Text -Path $ambiguousJsonPath -Content ($ambiguousDocument | ConvertTo-Json -Depth 30)
    $ambiguousBefore = Get-FileFingerprint -Root $ambiguousHome
    $ambiguousAudit = Invoke-Sanitizer -FixtureRoot $ambiguousHome
    Assert-True -Condition ($ambiguousAudit.exitCode -eq 1 -and @($ambiguousAudit.result.findings | Where-Object {
        $_.path -in @($ambiguousTomlPath, $ambiguousYamlPath, $ambiguousJsonPath) -and $_.status -ceq 'blocked'
    }).Count -eq 3) -Message '同名异路径或非结构化文字必须 blocked 而非删除。'
    $ambiguousApply = Invoke-Sanitizer -FixtureRoot $ambiguousHome -Mode Apply -ConfirmRetiredProject $retiredProject
    Assert-True -Condition ($ambiguousApply.exitCode -eq 1 -and -not [bool]$ambiguousApply.result.ok) -Message '存在同名异路径的 Apply 必须拒绝。'
    Assert-True -Condition ((Get-FileFingerprint -Root $ambiguousHome) -ceq $ambiguousBefore) -Message '同名异路径 blocked Apply 修改了 fixture。'
    Assert-True -Condition ([IO.File]::ReadAllText($ambiguousTomlPath).Contains('historical codex-gsd-codex-c-skill text must survive', [StringComparison]::Ordinal)) -Message '无关 TOML 文字被删除。'
    Assert-True -Condition ([IO.File]::ReadAllText($ambiguousYamlPath).Contains('D:\Users\fixture\codex-gsd-codex-c-skill', [StringComparison]::Ordinal)) -Message '同名 YAML 路径被删除。'
    $ambiguousJsonAfter = [IO.File]::ReadAllText($ambiguousJsonPath) | ConvertFrom-Json -AsHashtable -NoEnumerate
    Assert-True -Condition (@($ambiguousJsonAfter['electron-saved-workspace-roots']) -contains 'D:\Users\fixture\codex-gsd-codex-c-skill') -Message '同名 JSON 路径被删除。'
    Assert-NoSanitizerTemporaryPayloadFiles -Root $ambiguousHome

    $unicodeHome = New-FixtureHome -TestRoot $testRoot -Label unicode-escaped
    $unicodeTomlPath = Join-Path $unicodeHome 'backups_state\provider-sync\20260713T145129356Z\config.toml'
    $unicodeToml = @(
        '[mcp_servers.serena]'
        'args = ["start-mcp-server", "--project", "D:\\Codex\\projects\\\u0063odex-gsd-codex-c-skill"]'
        ''
        '[fixture.survivor]'
        'sentinel = "must-survive"'
        ''
    ) -join [Environment]::NewLine
    Write-Utf8Text -Path $unicodeTomlPath -Content $unicodeToml
    $unicodeYamlPath = Join-Path $unicodeHome 'backups_state\serena-dashboard-guard\fixture\serena_config.yml'
    $unicodeYaml = @(
        'projects:'
        '- "D:\\Codex\\projects\\\u0063odex-gsd-codex-c-skill"'
        "- $safeRoot"
        ''
    ) -join [Environment]::NewLine
    Write-Utf8Text -Path $unicodeYamlPath -Content $unicodeYaml
    $unicodeJsonPath = Join-Path $unicodeHome '.codex-global-state.json'
    $unicodeJson = '{"electron-saved-workspace-roots":["D:\\Codex\\projects\\\u0063odex-gsd-codex-c-skill","D:\\Codex\\projects\\统一环境"]}'
    Write-Utf8Text -Path $unicodeJsonPath -Content $unicodeJson
    foreach ($path in @($unicodeTomlPath, $unicodeYamlPath, $unicodeJsonPath)) {
        Assert-True -Condition (-not [IO.File]::ReadAllText($path).Contains($retiredProject, [StringComparison]::OrdinalIgnoreCase)) -Message "Unicode fixture 不得包含原始 retired marker：$path"
    }
    $unicodeAudit = Invoke-Sanitizer -FixtureRoot $unicodeHome
    Assert-True -Condition ($unicodeAudit.exitCode -eq 1 -and @($unicodeAudit.result.findings | Where-Object {
        $_.path -in @($unicodeTomlPath, $unicodeYamlPath, $unicodeJsonPath) -and $_.status -ceq 'ready'
    }).Count -eq 3) -Message 'Unicode-escaped retired path 必须被审计为精确清理目标。'
    $unicodeApply = Invoke-Sanitizer -FixtureRoot $unicodeHome -Mode Apply -ConfirmRetiredProject $retiredProject
    Assert-True -Condition ($unicodeApply.exitCode -eq 0 -and [bool]$unicodeApply.result.ok) -Message 'Unicode-escaped retired path Apply 必须成功。'
    foreach ($path in @($unicodeTomlPath, $unicodeYamlPath, $unicodeJsonPath)) {
        Assert-True -Condition (-not [IO.File]::ReadAllText($path).Contains($retiredProject, [StringComparison]::OrdinalIgnoreCase)) -Message "Unicode-escaped retired path 未清理：$path"
    }
    $unicodePostAudit = Invoke-Sanitizer -FixtureRoot $unicodeHome
    Assert-True -Condition ($unicodePostAudit.exitCode -eq 0 -and [bool]$unicodePostAudit.result.ok) -Message 'Unicode-escaped Apply 后 Audit 必须归零。'
    Assert-NoSanitizerTemporaryPayloadFiles -Root $unicodeHome

    $multilineUnicodeHome = New-FixtureHome -TestRoot $testRoot -Label multiline-unicode-escaped
    $multilineUnicodeTomlPath = Join-Path $multilineUnicodeHome '.config.toml.replace-backup.fixture'
    $multilineUnicodeToml = @(
        '[fixture.survivor]'
        'sentinel = "must-survive"'
        ''
        '[mcp_servers.serena]'
        'notes = """'
        'D:\\Codex\\projects\\\u0063odex-gsd-codex-c-skill'
        '"""'
        ''
    ) -join [Environment]::NewLine
    Write-Utf8Text -Path $multilineUnicodeTomlPath -Content $multilineUnicodeToml
    Assert-True -Condition (-not [IO.File]::ReadAllText($multilineUnicodeTomlPath).Contains($retiredProject, [StringComparison]::OrdinalIgnoreCase)) -Message 'multiline Unicode fixture 不得包含原始 retired marker。'
    $multilineUnicodeBefore = Get-FileFingerprint -Root $multilineUnicodeHome
    $multilineUnicodeAudit = Invoke-Sanitizer -FixtureRoot $multilineUnicodeHome
    Assert-True -Condition ($multilineUnicodeAudit.exitCode -eq 1 -and @($multilineUnicodeAudit.result.findings | Where-Object {
        $_.path -ceq $multilineUnicodeTomlPath -and $_.status -ceq 'blocked' -and $_.error -match 'multiline string'
    }).Count -eq 1) -Message 'multiline Unicode-escaped retired path 必须被明确 blocked，不能 Audit 清零。'
    $multilineUnicodeApply = Invoke-Sanitizer -FixtureRoot $multilineUnicodeHome -Mode Apply -ConfirmRetiredProject $retiredProject
    Assert-True -Condition ($multilineUnicodeApply.exitCode -eq 1 -and -not [bool]$multilineUnicodeApply.result.ok) -Message '含 multiline Unicode retired path 的 Apply 必须拒绝。'
    Assert-True -Condition ((Get-FileFingerprint -Root $multilineUnicodeHome) -ceq $multilineUnicodeBefore) -Message 'multiline Unicode blocked Apply 修改了 fixture。'
    Assert-NoSanitizerTemporaryPayloadFiles -Root $multilineUnicodeHome

    $rootMarkerHome = New-FixtureHome -TestRoot $testRoot -Label root-marker
    $rootMarkerPath = Join-Path $rootMarkerHome '.config.toml.replace-backup.fixture'
    $rootMarkerToml = @(
        'retired_project = "D:\\Codex\\projects\\codex-gsd-codex-c-skill"'
        '[fixture.survivor]'
        'sentinel = "must-survive"'
        ''
    ) -join "`n"
    Write-Utf8Text -Path $rootMarkerPath -Content $rootMarkerToml
    $rootMarkerPayloadBackupWatcher = Start-PayloadBackupWatcher -Root $rootMarkerHome
    $payloadBackupWatchers.Add($rootMarkerPayloadBackupWatcher)
    $rootMarkerBefore = Get-FileFingerprint -Root $rootMarkerHome
    $rootMarkerAudit = Invoke-Sanitizer -FixtureRoot $rootMarkerHome
    Assert-True -Condition ($rootMarkerAudit.exitCode -eq 1 -and @($rootMarkerAudit.result.findings | Where-Object {
        $_.path -ceq $rootMarkerPath -and $_.status -ceq 'blocked' -and $_.error -match '根级'
    }).Count -eq 1) -Message 'TOML 根级退休 marker 必须失败关闭。'
    $rootMarkerApply = Invoke-Sanitizer -FixtureRoot $rootMarkerHome -Mode Apply -ConfirmRetiredProject $retiredProject
    Assert-True -Condition ($rootMarkerApply.exitCode -eq 1 -and -not [bool]$rootMarkerApply.result.ok) -Message '含 TOML 根级 marker 的 Apply 必须拒绝。'
    Assert-True -Condition ((Get-FileFingerprint -Root $rootMarkerHome) -ceq $rootMarkerBefore) -Message '根级 marker 的 blocked Apply 修改了 fixture。'
    Assert-True -Condition (@(Get-PayloadBackupEvents -Watcher $rootMarkerPayloadBackupWatcher).Count -eq 0) -Message '被阻断的 Apply 不得创建旧内容 .bak payload。'
    Assert-NoSanitizerTemporaryPayloadFiles -Root $rootMarkerHome
    Stop-PayloadBackupWatcher -Watcher $rootMarkerPayloadBackupWatcher
    [void]$payloadBackupWatchers.Remove($rootMarkerPayloadBackupWatcher)

    $illegalHeaderHome = New-FixtureHome -TestRoot $testRoot -Label illegal-header
    $illegalHeaderPath = Join-Path $illegalHeaderHome '.config.toml.replace-backup.fixture'
    $illegalHeaderToml = @(
        '[[projects."D:\\Codex\\projects\\codex-gsd-codex-c-skill"]'
        'trust_level = "trusted"'
        ''
    ) -join "`n"
    Write-Utf8Text -Path $illegalHeaderPath -Content $illegalHeaderToml
    $illegalHeaderBefore = Get-FileFingerprint -Root $illegalHeaderHome
    $illegalHeaderAudit = Invoke-Sanitizer -FixtureRoot $illegalHeaderHome
    Assert-True -Condition ($illegalHeaderAudit.exitCode -eq 1 -and @($illegalHeaderAudit.result.findings | Where-Object {
        $_.path -ceq $illegalHeaderPath -and $_.status -ceq 'blocked' -and $_.error -match 'TOML table header'
    }).Count -eq 1) -Message '非法 TOML header 中的退休 marker 必须失败关闭。'
    $illegalHeaderApply = Invoke-Sanitizer -FixtureRoot $illegalHeaderHome -Mode Apply -ConfirmRetiredProject $retiredProject
    Assert-True -Condition ($illegalHeaderApply.exitCode -eq 1 -and -not [bool]$illegalHeaderApply.result.ok) -Message '含非法 TOML header 的 Apply 必须拒绝。'
    Assert-True -Condition ((Get-FileFingerprint -Root $illegalHeaderHome) -ceq $illegalHeaderBefore) -Message '非法 header 的 blocked Apply 修改了 fixture。'

    $malformedHome = New-FixtureHome -TestRoot $testRoot -Label malformed -MalformedWorkspaceRoots
    $malformedBefore = Get-FileFingerprint -Root $malformedHome
    $malformedAudit = Invoke-Sanitizer -FixtureRoot $malformedHome
    Assert-True -Condition ($malformedAudit.exitCode -eq 1 -and @($malformedAudit.result.findings | Where-Object { $_.status -ceq 'blocked' }).Count -gt 0) -Message '非预期 global-state 字段类型必须失败关闭。'
    $malformedApply = Invoke-Sanitizer -FixtureRoot $malformedHome -Mode Apply -ConfirmRetiredProject $retiredProject
    Assert-True -Condition ($malformedApply.exitCode -eq 1 -and -not [bool]$malformedApply.result.ok) -Message '存在 blocked target 的 Apply 必须拒绝。'
    Assert-True -Condition ((Get-FileFingerprint -Root $malformedHome) -ceq $malformedBefore) -Message 'blocked Apply 修改了任何 fixture 文件。'

    $malformedPromptHome = New-FixtureHome -TestRoot $testRoot -Label malformed-prompt-history -MalformedPromptHistory
    $malformedPromptAudit = Invoke-Sanitizer -FixtureRoot $malformedPromptHome
    Assert-True -Condition ($malformedPromptAudit.exitCode -eq 1 -and @($malformedPromptAudit.result.findings | Where-Object { $_.status -ceq 'ready' }).Count -gt 0) -Message '用户 prompt-history 的未知 schema 不得阻断受控 workspace 清理。'
    $malformedPromptApply = Invoke-Sanitizer -FixtureRoot $malformedPromptHome -Mode Apply -ConfirmRetiredProject $retiredProject
    Assert-True -Condition ($malformedPromptApply.exitCode -eq 0 -and [bool]$malformedPromptApply.result.ok) -Message '未知 prompt-history schema 不得阻止 Apply。'
    Assert-True -Condition ([IO.File]::ReadAllText((Join-Path $malformedPromptHome '.codex-global-state.json')).Contains($retiredProject, [StringComparison]::OrdinalIgnoreCase)) -Message '未知 prompt-history schema 中的用户文字被误删。'

    $liveRootRefusal = Invoke-Sanitizer -FixtureRoot 'D:\Codex\.codex'
    Assert-True -Condition ($liveRootRefusal.exitCode -eq 1 -and $liveRootRefusal.result.error -match 'live') -Message 'FixtureRoot=live Codex root 必须被拒绝。'
    $outsideAllowlistRefusal = Invoke-Sanitizer -FixtureRoot $ProjectRoot
    Assert-True -Condition ($outsideAllowlistRefusal.exitCode -eq 1 -and $outsideAllowlistRefusal.result.error -match 'reports') -Message 'allowlist 外 FixtureRoot 必须被拒绝。'

    $reparseTargetHome = New-FixtureHome -TestRoot $testRoot -Label reparse-target
    $reparseTargetExternal = Join-Path $testRoot 'external-reparse-target'
    $reparseToml = @(
        ('[projects."D:\\Codex\\projects\\{0}"]' -f $retiredProject)
        'trust_level = "trusted"'
        ''
    ) -join "`n"
    Write-Utf8Text -Path (Join-Path $reparseTargetExternal 'config.toml') -Content $reparseToml
    Remove-Item -LiteralPath (Join-Path $reparseTargetHome 'backups_state\provider-sync') -Recurse -Force
    New-Junction -Path (Join-Path $reparseTargetHome 'backups_state\provider-sync') -Target $reparseTargetExternal
    $reparseTargetAudit = Invoke-Sanitizer -FixtureRoot $reparseTargetHome
    Assert-True -Condition ($reparseTargetAudit.exitCode -eq 1 -and $reparseTargetAudit.result.findings[0].error -match 'reparse') -Message 'reparse target 必须被拒绝。'
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $reparseTargetExternal 'config.toml') -PathType Leaf) -Message 'reparse target 拒绝不得删除外部文件。'

    $reparseAncestorHome = New-FixtureHome -TestRoot $testRoot -Label reparse-ancestor
    $reparseAncestorExternal = Join-Path $testRoot 'external-reparse-ancestor'
    [IO.Directory]::CreateDirectory((Join-Path $reparseAncestorExternal 'provider-sync')) | Out-Null
    Write-Utf8Text -Path (Join-Path $reparseAncestorExternal 'provider-sync\config.toml') -Content $reparseToml
    Remove-Item -LiteralPath (Join-Path $reparseAncestorHome 'backups_state') -Recurse -Force
    New-Junction -Path (Join-Path $reparseAncestorHome 'backups_state') -Target $reparseAncestorExternal
    $reparseAncestorAudit = Invoke-Sanitizer -FixtureRoot $reparseAncestorHome
    Assert-True -Condition ($reparseAncestorAudit.exitCode -eq 1 -and $reparseAncestorAudit.result.findings[0].error -match 'reparse') -Message 'reparse ancestor 必须被拒绝。'
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $reparseAncestorExternal 'provider-sync\config.toml') -PathType Leaf) -Message 'reparse ancestor 拒绝不得删除外部文件。'

    Write-Output 'Retired project snapshot sanitizer: PASS (audit, explicit apply, live global-state schema, recursive thread associations, TOML/YAML, type/reparse/allowlist refusals)'
} finally {
    foreach ($payloadBackupWatcher in @($payloadBackupWatchers.ToArray())) {
        Stop-PayloadBackupWatcher -Watcher $payloadBackupWatcher
    }
    if (-not $KeepOutputs) {
        Remove-GeneratedTestTree -Path $testRoot
    }
}
