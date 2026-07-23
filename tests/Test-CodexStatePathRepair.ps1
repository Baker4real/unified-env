[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ProjectRoot = 'D:\Codex\projects\统一环境'
$ScriptPath = Join-Path $ProjectRoot 'scripts\Get-CodexStatePathInventory.ps1'
$FixtureParent = Join-Path $ProjectRoot 'reports\codex-state-path-repair-test'
$FixtureRoot = Join-Path $FixtureParent ([guid]::NewGuid().ToString('N'))
$CodexHome = Join-Path $FixtureRoot 'codex-home'
$StatePath = Join-Path $CodexHome '.codex-global-state.json'
$CandidateRoot = Join-Path $FixtureRoot 'candidate-root'

function Invoke-PathCommand {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'D:\Codex\tools\PowerShell\7.6.4\pwsh.exe'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @('-NoProfile', '-File', $ScriptPath) + $Arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $started = $false
    try {
        if (-not $process.Start()) { throw 'state path command did not start' }
        $started = $true
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $text = $stdout
        if (-not [string]::IsNullOrEmpty($stderr)) {
            if (-not [string]::IsNullOrEmpty($text) -and -not $text.EndsWith("`n")) { $text += [Environment]::NewLine }
            $text += $stderr
        }
        [pscustomobject]@{
            ExitCode = $process.ExitCode
            Text = $text
        }
    } finally {
        if ($started -and -not $process.HasExited) {
            try { $process.Kill($true); $process.WaitForExit() } catch {}
        }
        $process.Dispose()
    }
}

$testSource = Get-Content -Raw -LiteralPath $PSCommandPath
$helperStart = $testSource.IndexOf('function Invoke-PathCommand')
$helperEnd = $testSource.IndexOf('$testSource = Get-Content', $helperStart)
if ($helperStart -lt 0 -or $helperEnd -le $helperStart) { throw 'hidden state path helper is unavailable' }
$helperSource = $testSource.Substring($helperStart, $helperEnd - $helperStart)
if ($helperSource -cnotmatch 'UseShellExecute\s*=\s*\$false' -or $helperSource -cnotmatch 'CreateNoWindow\s*=\s*\$true') { throw 'state path test process must be hidden' }
$directPwshPattern = '&\s*' + [regex]::Escape("'D:\Codex\tools\PowerShell\7.6.4\pwsh.exe'")
if ($testSource -cmatch $directPwshPattern) { throw 'state path test must not directly invoke pwsh' }

try {
    New-Item -ItemType Directory -Path $CodexHome -Force | Out-Null
    New-Item -ItemType Directory -Path $CandidateRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $CandidateRoot '2026-07-13\new-chat') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $CandidateRoot '2026-06-03\c\outputs') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $CandidateRoot '2026-06-03\c\outputs\optimize-c-drive-admin.ps1') -Value 'fixture' -Encoding utf8NoBOM -NoNewline
    $junctionTarget = Join-Path $FixtureRoot 'junction-target'
    New-Item -ItemType Directory -Path $junctionTarget -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $CandidateRoot '2026-05-31') -Force | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $CandidateRoot '2026-05-31\project-b') -Target $junctionTarget | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $CandidateRoot '2026-06-03') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $FixtureRoot '.codex-state-path-repair-fixture') -Value 'codex-state-path-repair-test-v1' -Encoding utf8NoBOM -NoNewline
    Set-Content -LiteralPath (Join-Path $CodexHome 'config.toml') -Value ('approval_policy = "never"' + [Environment]::NewLine + 'sandbox_mode = "danger-full-access"' + [Environment]::NewLine) -Encoding utf8NoBOM -NoNewline
    $policy = '{"approvalPolicy":"never","sandboxPolicy":{"type":"dangerFullAccess"}}'
    Set-Content -LiteralPath (Join-Path $CodexHome 'policy.json') -Value $policy -Encoding utf8NoBOM -NoNewline
    Set-Content -LiteralPath (Join-Path $CodexHome 'state-policy.json') -Value $policy -Encoding utf8NoBOM -NoNewline

    $state = [ordered]@{
        'thread-workspace-root-hints' = [ordered]@{
            safe = 'C:\Users\WINDOWS\Documents\Codex\2026-07-13\new-chat'
            missing = 'C:\Users\WINDOWS\Documents\Codex\missing-task7-output'
            junction = 'C:\Users\WINDOWS\Documents\Codex\2026-05-31\project-b'
            ambiguousA = 'C:\Users\WINDOWS\Documents\Codex\2026-06-03'
            ambiguousB = 'C:\Users\WINDOWS\Documents\Codex\2026-06-03'
        }
        'thread-projectless-output-directories' = [ordered]@{
            safeFile = 'C:\Users\WINDOWS\Documents\Codex\2026-06-03\c\outputs\optimize-c-drive-admin.ps1'
        }
        untouched = [ordered]@{ sentinel = 'preserve' }
    }
    $state | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $StatePath -Encoding utf8NoBOM -NoNewline
    $before = [IO.File]::ReadAllBytes($StatePath)

    # Public seam 1: inventory is read-only and returns per-entry facts.
    $inventoryRun = Invoke-PathCommand -Arguments @('-Mode','Inventory','-FixtureRoot',$FixtureRoot,'-Json')
    if ($inventoryRun.ExitCode -ne 0) { throw "inventory 应成功：$($inventoryRun.Text)" }
    $inventory = $inventoryRun.Text | ConvertFrom-Json -Depth 32
    if ($inventory.ok -ne $true -or $inventory.readOnly -ne $true) { throw 'inventory 必须是成功只读结果。' }
    if ([string]$inventory.generationId -cnotmatch '^approval-v1-[0-9a-f]{32}$') { throw 'inventory generationId 非法。' }
    if ([string]$inventory.approvalArtifactPath -cne (Join-Path $FixtureRoot "evidence\approvals\$($inventory.generationId).json")) { throw 'approval artifact 路径非法。' }
    if ([string]$inventory.approvedMappingHash -cnotmatch '^[0-9a-f]{64}$') { throw 'approvedMappingHash 非法。' }
    $approvalArtifact = Get-Content -Raw -LiteralPath ([string]$inventory.approvalArtifactPath) | ConvertFrom-Json -Depth 64 -DateKind String
    $approvalProperties = @('artifactType','schemaVersion','generationId','coreInventoryGeneration','nonce','generatedAtUtc','expiresAtUtc','stateSha256','mappingSha256','approvedMappingHash','candidateRoot','approvedMap','entries','state','attestation')
    if (@(Compare-Object $approvalProperties @($approvalArtifact.PSObject.Properties.Name)).Count -ne 0 -or $approvalArtifact.attestation.protection -cne 'dpapi-current-user-v1') { throw 'approval artifact 认证闭包非法。' }
    if (@(Compare-Object $before ([IO.File]::ReadAllBytes($StatePath))).Count -ne 0) { throw 'inventory 修改了 state bytes。' }
    $entryProperties = @('mapName','identity','sourcePath','candidate','finalIdentity','reparse','disposition','reason')
    foreach ($entry in @($inventory.entries)) {
        if (@(Compare-Object $entryProperties @($entry.PSObject.Properties.Name)).Count -ne 0) { throw 'inventory entry schema 非法。' }
    }
    $safe = @($inventory.entries | Where-Object identity -eq 'safe')[0]
    $safeFile = @($inventory.entries | Where-Object identity -eq 'safeFile')[0]
    $missing = @($inventory.entries | Where-Object identity -eq 'missing')[0]
    $junction = @($inventory.entries | Where-Object identity -eq 'junction')[0]
    $ambiguous = @($inventory.entries | Where-Object identity -like 'ambiguous*')
    if ($safe.disposition -cne 'approved-candidate' -or $safe.candidate -cne (Join-Path $CandidateRoot '2026-07-13\new-chat')) { throw '安全目录映射分类错误。' }
    if ($safeFile.disposition -cne 'approved-candidate') { throw '安全文件映射分类错误。' }
    if ($missing.disposition -cne 'retained' -or $missing.reason -cne 'unresolved-missing') { throw 'missing 必须保留。' }
    if ($junction.disposition -cne 'retained' -or $junction.reason -cne 'unresolved-reparse' -or $junction.reparse -ne $true) { throw 'reparse 必须保留。' }
    if ($ambiguous.Count -ne 2 -or @($ambiguous | Where-Object { $_.disposition -cne 'retained' -or $_.reason -cne 'unresolved-ambiguous' }).Count -ne 0) { throw '重复最终身份必须全部保留为 ambiguous。' }

    # Public seam 2: generation/hash are the complete approval capability.
    $wrong = Invoke-PathCommand -Arguments @('-Mode','Repair','-FixtureRoot',$FixtureRoot,'-InventoryGeneration',$inventory.generationId,'-ApprovedMappingHash',('0' * 64),'-Json')
    if ($wrong.ExitCode -eq 0) { throw '错误 approval hash 必须拒绝。' }
    if (@(Compare-Object $before ([IO.File]::ReadAllBytes($StatePath))).Count -ne 0) { throw '拒绝路径修改了 state bytes。' }

    $repairRun = Invoke-PathCommand -Arguments @('-Mode','Repair','-FixtureRoot',$FixtureRoot,'-InventoryGeneration',$inventory.generationId,'-ApprovedMappingHash',$inventory.approvedMappingHash,'-Json')
    if ($repairRun.ExitCode -ne 0) { throw "repair 应成功：$($repairRun.Text)" }
    $repair = $repairRun.Text | ConvertFrom-Json -Depth 32
    if ($repair.ok -ne $true -or $repair.changed -ne $true) { throw 'repair 必须报告实际变更。' }
    if ([string]::IsNullOrWhiteSpace([string]$repair.evidencePath) -or -not (Test-Path -LiteralPath $repair.evidencePath -PathType Container)) { throw 'repair 必须留下 fixture evidence。' }
    $after = Get-Content -Raw -LiteralPath $StatePath | ConvertFrom-Json -Depth 32
    if ($after.'thread-workspace-root-hints'.safe -cne $safe.candidate) { throw '安全目录映射未修复。' }
    if ($after.'thread-projectless-output-directories'.safeFile -cne $safeFile.candidate) { throw '安全文件映射未修复。' }
    if ($after.'thread-workspace-root-hints'.missing -cne $missing.sourcePath) { throw 'missing 条目不应改变。' }
    if ($after.'thread-workspace-root-hints'.junction -cne $junction.sourcePath) { throw 'reparse 条目不应改变。' }
    foreach ($entry in $ambiguous) {
        if ($after.'thread-workspace-root-hints'.($entry.identity) -cne $entry.sourcePath) { throw 'ambiguous 条目不应改变。' }
    }
    if ($after.untouched.sentinel -cne 'preserve') { throw '未知字段未保留。' }
    $manifestPath = Join-Path $repair.evidencePath 'manifest.json'
    $manifestBytes = [IO.File]::ReadAllBytes($manifestPath)
    $manifest = [Text.UTF8Encoding]::new($false, $true).GetString($manifestBytes) | ConvertFrom-Json -Depth 32
    $manifestProperties = @('artifactType','schemaVersion','generationId','status','beforeBackupRelativePath','beforeBackupSha256','beforeIdentity','afterSha256','afterIdentity','attestationSha256','applyIntentAttestationSha256','completionAttestationSha256','restoreIntentAttestationSha256','restoredIdentity','restoreAttestationSha256','approvalArtifactSha256','entries','recovery')
    if (@(Compare-Object $manifestProperties @($manifest.PSObject.Properties.Name)).Count -ne 0) { throw 'evidence manifest schema 非法。' }
    if ($manifest.artifactType -cne 'env-governance.codex-state-path-repair-manifest' -or $manifest.status -cne 'completed' -or $manifest.generationId -cne $inventory.generationId) { throw 'evidence approval binding 非法。' }
    if ($manifest.afterSha256 -cne (Get-FileHash -LiteralPath $StatePath -Algorithm SHA256).Hash.ToLowerInvariant()) { throw 'evidence 写后 hash 非法。' }
    if (@($manifest.afterIdentity).Count -ne 2 -or [string]$manifest.applyIntentAttestationSha256 -cnotmatch '^[0-9a-f]{64}$' -or [string]$manifest.completionAttestationSha256 -cnotmatch '^[0-9a-f]{64}$' -or -not (Test-Path -LiteralPath (Join-Path $repair.evidencePath 'apply-intent.json') -PathType Leaf) -or -not (Test-Path -LiteralPath (Join-Path $repair.evidencePath 'completion-attestation.json') -PathType Leaf)) { throw 'evidence completion identity 认证非法。' }
    foreach ($repairEntry in @($repair.entries)) {
        $evidenceEntry = @($manifest.entries | Where-Object { $_.mapName -ceq $repairEntry.mapName -and $_.identity -ceq $repairEntry.identity })
        if ($evidenceEntry.Count -ne 1) { throw 'evidence entries identity 闭包非法。' }
        foreach ($field in $entryProperties) {
            if (($evidenceEntry[0].$field | ConvertTo-Json -Depth 8 -Compress) -cne ($repairEntry.$field | ConvertTo-Json -Depth 8 -Compress)) { throw "evidence entry 字段未绑定：$($repairEntry.identity)/$field" }
        }
    }

    # A stale generation must fail closed after any state change.
    $after | Add-Member -NotePropertyName concurrent -NotePropertyValue 'third-party' -Force
    $after | ConvertTo-Json -Depth 32 -Compress | Set-Content -LiteralPath $StatePath -Encoding utf8NoBOM -NoNewline
    $staleBytes = [IO.File]::ReadAllBytes($StatePath)
    $stale = Invoke-PathCommand -Arguments @('-Mode','Repair','-FixtureRoot',$FixtureRoot,'-InventoryGeneration',$inventory.generationId,'-ApprovedMappingHash',$inventory.approvedMappingHash,'-Json')
    if ($stale.ExitCode -eq 0) { throw '过期 generation 必须拒绝。' }
    if (@(Compare-Object $staleBytes ([IO.File]::ReadAllBytes($StatePath))).Count -ne 0) { throw '过期 generation 拒绝后 bytes 改变。' }

    'Test-CodexStatePathRepair: PASS'
} finally {
    if (Test-Path -LiteralPath $FixtureRoot) {
        Remove-Item -LiteralPath $FixtureRoot -Recurse -Force
    }
    if ((Test-Path -LiteralPath $FixtureParent) -and @(Get-ChildItem -LiteralPath $FixtureParent -Force).Count -eq 0) {
        Remove-Item -LiteralPath $FixtureParent -Force
    }
}
