param(
    [string]$ProjectRoot = 'D:\agents\projects\统一环境',
    [ValidateSet('acl','legacy','final')][string]$OnlyPostPhase,
    [switch]$OnlyRestoreContract,
    [switch]$OnlyRestoreThirdVersion,
    [switch]$OnlyRestoreResume,
    [switch]$OnlyRestoreAttestationTamper,
    [switch]$OnlyCreatedDirectoryCleanupReplace,
    [switch]$OnlyRestoreProgressTamper,
    [switch]$OnlyRestoreTerminalDrift,
    [switch]$OnlyRestoreManifestHardening,
    [switch]$OnlyRestoreManifestCas,
    [switch]$OnlyRestoreBackupSnapshot,
    [switch]$OnlyRestoreRetirementIrreversibility,
    [switch]$OnlyRestoreAclReplace,
    [switch]$OnlyPostCleanupReplace
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-Sha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

. (Join-Path $ProjectRoot 'scripts\lib\CodexHookPolicy.ps1')

function Invoke-HiddenChildProcess {
    [CmdletBinding(DefaultParameterSetName = 'ArgumentList')]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(ParameterSetName = 'ArgumentList')][string[]]$ArgumentList = @(),
        [Parameter(Mandatory, ParameterSetName = 'RawArguments')][AllowEmptyString()][string]$RawArguments,
        [AllowEmptyString()][string]$InputText = '',
        [hashtable]$Environment = @{}
    )

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FilePath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    if ($PSCmdlet.ParameterSetName -ceq 'RawArguments') {
        $start.Arguments = $RawArguments
    } else {
        foreach ($argument in $ArgumentList) { [void]$start.ArgumentList.Add($argument) }
    }
    foreach ($name in $Environment.Keys) { $start.Environment[[string]$name] = [string]$Environment[$name] }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $started = $false
    try {
        $started = $process.Start()
        Assert-True $started "child process 无法启动：$FilePath"
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($InputText)
        $process.StandardInput.Close()
        Assert-True ($process.WaitForExit(10000)) "child process 超过10秒：$FilePath"
        [pscustomobject]@{
            exitCode = $process.ExitCode
            stdout = $stdoutTask.GetAwaiter().GetResult()
            stderr = $stderrTask.GetAwaiter().GetResult()
        }
    } finally {
        if ($started -and -not $process.HasExited) { try { $process.Kill($true) } catch {} }
        $process.Dispose()
    }
}

function Get-RestoreTargetFingerprint([string]$CodexHome, [object]$HostManifest, [object]$EvidenceManifest, [string]$ContextPath) {
    $parts = [Collections.Generic.List[string]]::new()
    foreach ($path in @(
        (Join-Path $CodexHome 'hooks.json'),
        (Join-Path $CodexHome 'config.toml'),
        (Join-Path $CodexHome '.fixture-user-environment.json'),
        $ContextPath
    )) { $parts.Add("file:$path=$(Get-Sha256 $path)") }
    foreach ($file in @($HostManifest.files)) {
        $path = Join-Path (Join-Path $CodexHome 'hooks') ([string]$file.liveRelativePath)
        $parts.Add("managed:$path=$(if(Test-Path -LiteralPath $path -PathType Leaf){Get-Sha256 $path}else{'missing'})")
    }
    foreach ($name in @($EvidenceManifest.retiredResources)) {
        $path = Join-Path (Join-Path $CodexHome 'hooks') ([string]$name)
        $parts.Add("retired:$path=$(if(Test-Path -LiteralPath $path -PathType Leaf){Get-Sha256 $path}else{'missing'})")
    }
    foreach ($path in @($EvidenceManifest.aclTargets)) {
        if (Test-Path -LiteralPath ([string]$path)) { $parts.Add("acl:$path=$((Get-Acl -LiteralPath ([string]$path)).Sddl)") }
    }
    $parts -join "`n"
}

function New-FunctionalHookFixture([string]$CodexHome) {
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    New-Item -ItemType Directory -Force -Path (Join-Path $CodexHome 'hooks') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $CodexHome '.codex-host-hook-reconciliation-fixture'), 'codex-host-hook-reconciliation-fixture-v1', $utf8)
    $contextPath = Join-Path ([System.IO.Directory]::GetParent($CodexHome).FullName) '.serena\contexts\codex-file-tools.yml'
    New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($contextPath)) | Out-Null
    $context = @'
prompt: |
  [codex-serena-activation-policy:v1 mandatory]
  Codex owns shell execution; Serena provides project-scoped semantic tools.
  Before using any project-scoped Serena tool in a repository task, explicitly
  call activate_project with the absolute current workspace or repository root
  from Codex's environment_context, then verify the result with
  get_current_config. Never infer the task project from Serena's initial active
  project or from the Serena process working directory.
'@
    [System.IO.File]::WriteAllText($contextPath, $context, $utf8)
    $escapedContext = $contextPath.Replace('\', '\\')
    $config = @"
model = "fixture-model"
approval_policy = "on-request"
sandbox_mode = "workspace-write"

[mcp_servers.serena]
command = "cmd.exe"
args = [ "/c", 'D:\Codex\.codex\scripts\start-serena-mcp.cmd', "start-mcp-server", '--context=$contextPath', "--project-from-cwd", "--enable-web-dashboard=true", "--open-web-dashboard=false" ]

[mcp_servers.serena.env]
SERENA_HOME = "D:\\Codex\\.serena"

[features]
hooks = true
unified_exec = true
"@
    [System.IO.File]::WriteAllText((Join-Path $CodexHome 'config.toml'), $config, $utf8)
    $registry = [ordered]@{
        schemaVersion = 9
        owner = 'unknown-owner-must-survive'
        hooks = [ordered]@{
            UnknownEvent = @([ordered]@{ custom = 'unknown-event-must-survive' })
            SessionStart = @([ordered]@{
                customGroup = 'unknown-group-must-survive'
                hooks = @([ordered]@{ type = 'command'; command = 'D:\Unknown\keep.cmd'; timeout = 7; customEntry = 'keep' })
            })
        }
    }
    [System.IO.File]::WriteAllText((Join-Path $CodexHome 'hooks.json'), (($registry | ConvertTo-Json -Depth 20) + "`n"), $utf8)
    [System.IO.File]::WriteAllText((Join-Path $CodexHome 'hooks\unknown-preserve.txt'), 'unknown-live-file-must-survive', $utf8)
    [System.IO.File]::WriteAllText((Join-Path $CodexHome '.fixture-user-environment.json'), '{"SERENA_HOME":"D:\\hermes-data\\.serena"}', $utf8)
}

function Invoke-Reconciler([string]$ScriptPath, [string]$Mode, [string]$CodexHome) {
    $raw = & $ScriptPath -Mode $Mode -CodexHome $CodexHome -Json
    (($raw | Out-String).Trim() | ConvertFrom-Json)
}

function Invoke-PublicWrapper([string]$Path, [string]$InputText, [string[]]$ArgumentList = @(), [hashtable]$Environment = @{}) {
    $quotedArguments = @($ArgumentList | ForEach-Object { '"' + ([string]$_).Replace('"', '""') + '"' }) -join ' '
    Invoke-HiddenChildProcess `
        -FilePath 'C:\Windows\System32\cmd.exe' `
        -RawArguments ('/d /s /c ""' + $Path + '" ' + $quotedArguments + '"') `
        -InputText $InputText `
        -Environment $Environment
}

$manifestPath = Join-Path $ProjectRoot 'managed\codex-hooks\host-preflight-manifest.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
Assert-True (@($manifest.hooks).Count -eq 5) 'production manifest 必须精确包含5个功能 hook'
Assert-True (@($manifest.files).Count -eq 12) 'production manifest 必须精确包含12个 active 文件'
Assert-True (@($manifest.environment).Count -eq 1 -and $manifest.environment[0].name -ceq 'SERENA_HOME') 'production manifest 必须精确包含 User SERENA_HOME action'
$hookIds = @($manifest.hooks | ForEach-Object id)
foreach ($retiredId in @('serena-auto-approve','provider-stability','codex-state-policy','serena-dashboard')) {
    Assert-True ($hookIds -cnotcontains $retiredId) "production manifest 不得包含退役 hook：$retiredId"
}
Assert-True ($hookIds -ccontains 'github-cli') 'production manifest 必须重新注册 github-cli'
$sourceHashesBefore = @{}
foreach ($file in @($manifest.files)) {
    $sourceHashesBefore[$file.relativePath] = Get-Sha256 (Join-Path $ProjectRoot "managed\codex-hooks\$($file.relativePath)")
}

$testRoot = Join-Path $ProjectRoot ('.scratch\host-hook-reconciliation-tests-' + [guid]::NewGuid().ToString('N'))
$codexHome = Join-Path $testRoot 'functional hooks & canary\.codex'
$scriptPath = Join-Path $ProjectRoot 'scripts\Invoke-CodexHostHookReconciliation.ps1'
$realSerenaHomeBefore = [Environment]::GetEnvironmentVariable('SERENA_HOME', 'User')
try {
    if ($OnlyCreatedDirectoryCleanupReplace) {
        $cleanupHome = Join-Path $testRoot 'created-directory-cleanup\.codex'
        $cleanupTarget = Join-Path $cleanupHome 'hooks\lib'
        $cleanupMoved = "$cleanupTarget.fixture-cleanup-moved"
        $cleanupExternal = Join-Path $testRoot 'created-directory-cleanup-external'
        New-FunctionalHookFixture -CodexHome $cleanupHome
        New-Item -ItemType Directory -Force -Path $cleanupExternal | Out-Null
        [IO.File]::WriteAllText((Join-Path $cleanupExternal 'third-party-sentinel.txt'), 'third-party-directory-must-survive', [Text.UTF8Encoding]::new($false))
        $externalBefore = Get-Sha256 (Join-Path $cleanupExternal 'third-party-sentinel.txt')
        $env:CODEX_HOST_HOOK_TEST_POST_COMMIT_FAILURE = 'environment'
        $env:CODEX_HOST_HOOK_TEST_CREATED_DIRECTORY_CLEANUP_REPLACE = ([ordered]@{
            targetParent = $cleanupTarget
            externalParent = $cleanupExternal
        } | ConvertTo-Json -Compress)
        $failed = $false
        $failureMessage = ''
        try { & $scriptPath -Mode Repair -CodexHome $cleanupHome -Json | Out-Null } catch { $failed = $true; $failureMessage = $_.Exception.Message } finally {
            Remove-Item Env:CODEX_HOST_HOOK_TEST_POST_COMMIT_FAILURE -ErrorAction SilentlyContinue
            Remove-Item Env:CODEX_HOST_HOOK_TEST_CREATED_DIRECTORY_CLEANUP_REPLACE -ErrorAction SilentlyContinue
        }
        try {
            Assert-True $failed 'created-directory cleanup replacement seam 必须使 Repair 失败'
            Assert-True ((Get-Sha256 (Join-Path $cleanupExternal 'third-party-sentinel.txt')) -ceq $externalBefore) '目录清理不得改写替代目录内容'
            Assert-True (Test-Path -LiteralPath $cleanupMoved -PathType Container) "目录清理不得删除被移动的原始目录 identity；Repair=$failureMessage"
            Assert-True (Test-Path -LiteralPath $cleanupTarget -PathType Container) '目录清理不得删除第三方替代目录入口'
            $replacementItem = Get-Item -LiteralPath $cleanupTarget -Force
            Assert-True (($replacementItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) 'fixture 必须真实建立替代 junction'
            $cleanupEvidence = @(Get-ChildItem -LiteralPath (Join-Path $cleanupHome 'run-evidence\host-hook-remediation') -Directory)
            Assert-True ($cleanupEvidence.Count -eq 1) 'created-directory cleanup replacement evidence 必须唯一'
            $cleanupManifest = Get-Content -LiteralPath (Join-Path $cleanupEvidence[0].FullName 'manifest.json') -Raw | ConvertFrom-Json
            Assert-True ($cleanupManifest.status -ceq 'unsafe-partial') '目录 identity 漂移必须记录 unsafe-partial，不能误报 rolled-back'
            Assert-True (@($cleanupManifest.rollbackErrors).Count -eq 1) '目录 identity 漂移必须产生精确 rollback error'
        } finally {
            if ((Test-Path -LiteralPath $cleanupTarget) -and ((Get-Item -LiteralPath $cleanupTarget -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                $cleanupResult = Invoke-HiddenChildProcess -FilePath 'C:\Windows\System32\cmd.exe' -ArgumentList @('/d','/c','rmdir',$cleanupTarget)
                Assert-True ($cleanupResult.exitCode -eq 0) "目录清理 fixture junction 删除失败：$($cleanupResult.stderr)"
            }
            if ((Test-Path -LiteralPath $cleanupMoved -PathType Container) -and -not (Test-Path -LiteralPath $cleanupTarget)) {
                Move-Item -LiteralPath $cleanupMoved -Destination $cleanupTarget
            }
        }
        'Test-CodexFunctionalHookRegistration.ps1 -OnlyCreatedDirectoryCleanupReplace: PASS'
        return
    }

    New-FunctionalHookFixture -CodexHome $codexHome
    $retiredDirectoryFilePath = Join-Path $codexHome 'hooks\__pycache__\codex-mobile-permission-guard.cpython-313.pyc'
    if ($OnlyRestoreRetirementIrreversibility) {
        New-Item -ItemType Directory -Path (Join-Path $codexHome 'hooks\__pycache__') | Out-Null
        [IO.File]::WriteAllText($retiredDirectoryFilePath, 'fixture:allowlisted-retired-pyc', [Text.UTF8Encoding]::new($false))
    }
    $checkFingerprintBefore = @(
        Get-Sha256 (Join-Path $codexHome 'hooks.json')
        Get-Sha256 (Join-Path $codexHome '.fixture-user-environment.json')
        Get-Sha256 (Join-Path $codexHome 'hooks\unknown-preserve.txt')
    )
    $check = Invoke-Reconciler -ScriptPath $scriptPath -Mode Check -CodexHome $codexHome
    Assert-True (-not [bool]$check.ok) 'Check 必须识别未发布文件、环境与 registry drift'
    $expectedProjectionFields = @(
        'identity', 'id', 'event', 'order', 'matcher', 'timeoutSeconds',
        'sourceSha256', 'wrapperSha256', 'implementationSha256', 'runtimeSha256',
        'launcherImplementationSha256', 'launcherRuntimeSha256',
        'trustRequired', 'restartRequired'
    )
    Assert-True ($check.PSObject.Properties.Name -ccontains 'registrationProjection') 'Check 必须输出确定性的 per-hook registration projection'
    Assert-True (@($check.registrationProjection).Count -eq 5) 'Check registration projection 必须精确包含5个 hook'
    foreach ($projection in @($check.registrationProjection)) {
        Assert-True ((@($projection.PSObject.Properties.Name) -join ',') -ceq ($expectedProjectionFields -join ',')) "registration projection schema 非法：$($projection.id)"
        foreach ($hashName in @('identity','sourceSha256','wrapperSha256','implementationSha256','runtimeSha256','launcherImplementationSha256','launcherRuntimeSha256')) {
            $hashValue = $projection.$hashName
            if ($hashName -cin @('launcherImplementationSha256', 'launcherRuntimeSha256') -and $null -eq $hashValue) {
                Assert-True ($projection.id -ceq 'github-cli') "无 launcher 的 production hook 只能是 github-cli：$($projection.id)"
                continue
            }
            Assert-True ([string]$hashValue -cmatch '^[0-9a-f]{64}$') "registration projection $hashName 必须为脱敏 SHA-256：$($projection.id)"
        }
    }
    $checkFingerprintAfter = @(
        Get-Sha256 (Join-Path $codexHome 'hooks.json')
        Get-Sha256 (Join-Path $codexHome '.fixture-user-environment.json')
        Get-Sha256 (Join-Path $codexHome 'hooks\unknown-preserve.txt')
    )
    Assert-True (($checkFingerprintBefore -join '|') -ceq ($checkFingerprintAfter -join '|')) 'Check 必须严格只读'

    $repair = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $codexHome
    Assert-True ([bool]$repair.ok -and [bool]$repair.changed) 'Repair 必须收敛功能 hooks'
    $successManifest = Get-Content -LiteralPath (Join-Path $repair.evidencePath 'manifest.json') -Raw | ConvertFrom-Json
    Assert-True ($successManifest.status -ceq 'completed') '成功 evidence 必须为 completed'
    Assert-True (@($successManifest.committedResources)[-1] -ceq 'hooks.json') 'registry 必须是最后提交资源'

    if ($OnlyRestoreAclReplace) {
        $aclTarget = Join-Path $codexHome 'hooks\unknown-preserve.txt'
        $aclParked = Join-Path $codexHome 'hooks\unknown-preserve.fixture-parked.txt'
        $aclExternal = Join-Path $testRoot 'acl-external-must-survive.txt'
        [IO.File]::WriteAllText($aclExternal, 'external-bytes-and-acl-must-survive', [Text.UTF8Encoding]::new($false))
        $targetHashBefore = Get-Sha256 $aclTarget
        $externalHashBefore = Get-Sha256 $aclExternal
        $externalSddlBefore = (Get-Acl -LiteralPath $aclExternal).Sddl
        $env:CODEX_HOST_HOOK_TEST_RESTORE_ACL_REPLACE = ([ordered]@{
            targetPath = $aclTarget
            parkedPath = $aclParked
            externalPath = $aclExternal
        } | ConvertTo-Json -Compress)
        $restoreFailed = $false
        try {
            & $scriptPath -Mode Restore -CodexHome $codexHome -EvidencePath $repair.evidencePath -Json | Out-Null
        } catch {
            $restoreFailed = $true
        } finally {
            Remove-Item Env:CODEX_HOST_HOOK_TEST_RESTORE_ACL_REPLACE -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $aclParked -PathType Leaf) {
                if (Test-Path -LiteralPath $aclTarget -PathType Leaf) { [IO.File]::Delete($aclTarget) }
                Move-Item -LiteralPath $aclParked -Destination $aclTarget
            }
        }
        Assert-True $restoreFailed 'ACL preflight 后 replacement 尝试必须使 Restore fail-closed'
        Assert-True ((Get-Sha256 $aclTarget) -ceq $targetHashBefore) 'ACL replacement 拒绝不得改变受权 target bytes/identity path'
        Assert-True ((Get-Sha256 $aclExternal) -ceq $externalHashBefore) 'ACL replacement 拒绝不得改变外部 bytes'
        Assert-True ((Get-Acl -LiteralPath $aclExternal).Sddl -ceq $externalSddlBefore) 'ACL replacement 拒绝不得改变外部 ACL'
        $blockedManifest = Get-Content -LiteralPath (Join-Path $repair.evidencePath 'manifest.json') -Raw | ConvertFrom-Json
        Assert-True ($blockedManifest.status -ceq 'restore-blocked') 'ACL replacement 必须记录 restore-blocked'
        Assert-True ((@($blockedManifest.recoveryRequired) -join ',') -ceq "acl:$aclTarget") 'ACL replacement recoveryRequired 必须精确指向受权 target'
        'Test-CodexFunctionalHookRegistration.ps1 -OnlyRestoreAclReplace: PASS'
        return
    }

    if ($OnlyRestoreAttestationTamper) {
        $backupPath = Join-Path $repair.evidencePath 'hooks.json'
        [IO.File]::WriteAllText($backupPath, '{"schemaVersion":9,"hooks":{},"injected":"must-not-restore"}', [Text.UTF8Encoding]::new($false))
        $tamperedManifestPath = Join-Path $repair.evidencePath 'manifest.json'
        $tamperedManifest = Get-Content -LiteralPath $tamperedManifestPath -Raw | ConvertFrom-Json
        $tamperedManifest.originalHashes.'hooks.json' = Get-Sha256 $backupPath
        [IO.File]::WriteAllText($tamperedManifestPath, (($tamperedManifest | ConvertTo-Json -Depth 30) + "`n"), [Text.UTF8Encoding]::new($false))
        $targetBeforeTamperedRestore = Get-RestoreTargetFingerprint -CodexHome $codexHome -HostManifest $manifest -EvidenceManifest $tamperedManifest -ContextPath (Join-Path ([IO.Directory]::GetParent($codexHome).FullName) '.serena\contexts\codex-file-tools.yml')
        $tamperedRestoreFailed = $false
        try { & $scriptPath -Mode Restore -CodexHome $codexHome -EvidencePath $repair.evidencePath -Json | Out-Null } catch { $tamperedRestoreFailed = $true }
        Assert-True $tamperedRestoreFailed '协调篡改 manifest+backup 必须被 evidence attestation 拒绝'
        $targetAfterTamperedRestore = Get-RestoreTargetFingerprint -CodexHome $codexHome -HostManifest $manifest -EvidenceManifest $tamperedManifest -ContextPath (Join-Path ([IO.Directory]::GetParent($codexHome).FullName) '.serena\contexts\codex-file-tools.yml')
        Assert-True ($targetAfterTamperedRestore -ceq $targetBeforeTamperedRestore) 'attestation 失败必须保持所有目标零写'
        'Test-CodexFunctionalHookRegistration.ps1 -OnlyRestoreAttestationTamper: PASS'
        return
    }

    if ($OnlyRestoreProgressTamper) {
        $progressManifestPath = Join-Path $repair.evidencePath 'manifest.json'
        $progressManifest = Get-Content -LiteralPath $progressManifestPath -Raw | ConvertFrom-Json
        $progressManifest.status = 'restoring'
        $progressManifest.restoreProgress = @('hooks.json','hooks.json')
        [IO.File]::WriteAllText($progressManifestPath, (($progressManifest | ConvertTo-Json -Depth 30) + "`n"), [Text.UTF8Encoding]::new($false))
        $fingerprintBeforeProgressRestore = Get-RestoreTargetFingerprint -CodexHome $codexHome -HostManifest $manifest -EvidenceManifest $progressManifest -ContextPath (Join-Path ([IO.Directory]::GetParent($codexHome).FullName) '.serena\contexts\codex-file-tools.yml')
        $progressRestoreFailed = $false
        try { & $scriptPath -Mode Restore -CodexHome $codexHome -EvidencePath $repair.evidencePath -Json | Out-Null } catch { $progressRestoreFailed = $true }
        Assert-True $progressRestoreFailed '重复 restoreProgress 必须在任何目标写入前拒绝'
        $fingerprintAfterProgressRestore = Get-RestoreTargetFingerprint -CodexHome $codexHome -HostManifest $manifest -EvidenceManifest $progressManifest -ContextPath (Join-Path ([IO.Directory]::GetParent($codexHome).FullName) '.serena\contexts\codex-file-tools.yml')
        Assert-True ($fingerprintAfterProgressRestore -ceq $fingerprintBeforeProgressRestore) '非法 restoreProgress 必须保持所有目标零写'
        'Test-CodexFunctionalHookRegistration.ps1 -OnlyRestoreProgressTamper: PASS'
        return
    }

    if ($OnlyRestoreTerminalDrift) {
        $env:CODEX_HOST_HOOK_TEST_RESTORE_FINAL_DRIFT = 'hooks.json'
        $failed = $false
        try { & $scriptPath -Mode Restore -CodexHome $codexHome -EvidencePath $repair.evidencePath -Json | Out-Null } catch { $failed = $true }
        finally { Remove-Item Env:CODEX_HOST_HOOK_TEST_RESTORE_FINAL_DRIFT -ErrorAction SilentlyContinue }
        Assert-True $failed '最后 action 后 target 漂移必须使 Restore 失败'
        $blocked = Get-Content -LiteralPath (Join-Path $repair.evidencePath 'manifest.json') -Raw | ConvertFrom-Json
        Assert-True ($blocked.status -ceq 'restore-blocked') 'terminal postcheck 失败必须持久化 restore-blocked'
        Assert-True (@($blocked.recoveryRequired) -ccontains 'terminal-postcheck') 'terminal postcheck 失败必须给出 recoveryRequired'
        Assert-True ((Get-Sha256 (Join-Path $codexHome 'hooks.json')) -cne $checkFingerprintBefore[0]) 'terminal drift 第三版本不得被覆盖'
        'Test-CodexFunctionalHookRegistration.ps1 -OnlyRestoreTerminalDrift: PASS'
        return
    }

    if ($OnlyRestoreManifestHardening) {
        $manifestPath = Join-Path $repair.evidencePath 'manifest.json'
        $originalText = [IO.File]::ReadAllText($manifestPath, [Text.UTF8Encoding]::new($false, $true))
        $cases = [Collections.Generic.List[object]]::new()
        $cases.Add([pscustomobject]@{ name='duplicate-key'; text=($originalText -replace '^\{', '{"schemaVersion":1,') })
        $unknown = $originalText | ConvertFrom-Json; $unknown | Add-Member -NotePropertyName unknownProperty -NotePropertyValue 1
        $cases.Add([pscustomobject]@{ name='unknown-property'; text=(($unknown | ConvertTo-Json -Depth 40) + "`n") })
        $missing = $originalText | ConvertFrom-Json; $missing.PSObject.Properties.Remove('error')
        $cases.Add([pscustomobject]@{ name='missing-property'; text=(($missing | ConvertTo-Json -Depth 40) + "`n") })
        $invalid = $originalText | ConvertFrom-Json; $invalid.status = 'prepared'
        $cases.Add([pscustomobject]@{ name='invalid-status'; text=(($invalid | ConvertTo-Json -Depth 40) + "`n") })
        foreach ($progressCase in @(
            [pscustomobject]@{ name='progress-skip'; values=@('environment:SERENA_HOME') },
            [pscustomobject]@{ name='progress-unknown'; values=@('unknown-action') },
            [pscustomobject]@{ name='progress-out-of-order'; values=@('hooks.json','config.toml') }
        )) {
            $document = $originalText | ConvertFrom-Json
            $document.status = 'restoring'; $document.restoreProgress = $progressCase.values
            $cases.Add([pscustomobject]@{ name=$progressCase.name; text=(($document | ConvertTo-Json -Depth 40) + "`n") })
        }
        foreach ($case in $cases) {
            [IO.File]::WriteAllText($manifestPath, [string]$case.text, [Text.UTF8Encoding]::new($false))
            $before = Get-RestoreTargetFingerprint -CodexHome $codexHome -HostManifest $manifest -EvidenceManifest ($originalText | ConvertFrom-Json) -ContextPath (Join-Path ([IO.Directory]::GetParent($codexHome).FullName) '.serena\contexts\codex-file-tools.yml')
            $failed = $false
            try { & $scriptPath -Mode Restore -CodexHome $codexHome -EvidencePath $repair.evidencePath -Json | Out-Null } catch { $failed = $true }
            Assert-True $failed "非法 manifest 必须拒绝：$($case.name)"
            $after = Get-RestoreTargetFingerprint -CodexHome $codexHome -HostManifest $manifest -EvidenceManifest ($originalText | ConvertFrom-Json) -ContextPath (Join-Path ([IO.Directory]::GetParent($codexHome).FullName) '.serena\contexts\codex-file-tools.yml')
            Assert-True ($after -ceq $before) "非法 manifest 必须目标零写：$($case.name)"
        }
        'Test-CodexFunctionalHookRegistration.ps1 -OnlyRestoreManifestHardening: PASS'
        return
    }

    if ($OnlyRestoreManifestCas) {
        $manifestPath = Join-Path $repair.evidencePath 'manifest.json'
        $before = Get-RestoreTargetFingerprint -CodexHome $codexHome -HostManifest $manifest -EvidenceManifest $successManifest -ContextPath (Join-Path ([IO.Directory]::GetParent($codexHome).FullName) '.serena\contexts\codex-file-tools.yml')
        $env:CODEX_HOST_HOOK_TEST_RESTORE_MANIFEST_CAS_REPLACE = '1'
        $failed = $false
        try { & $scriptPath -Mode Restore -CodexHome $codexHome -EvidencePath $repair.evidencePath -Json | Out-Null } catch { $failed = $true }
        finally { Remove-Item Env:CODEX_HOST_HOOK_TEST_RESTORE_MANIFEST_CAS_REPLACE -ErrorAction SilentlyContinue }
        Assert-True $failed 'manifest CAS 丢失必须拒绝 Restore'
        Assert-True ([IO.File]::ReadAllText($manifestPath).EndsWith(" `r`n") -or [IO.File]::ReadAllText($manifestPath).EndsWith(" `n")) '竞争 manifest 必须保留'
        $after = Get-RestoreTargetFingerprint -CodexHome $codexHome -HostManifest $manifest -EvidenceManifest $successManifest -ContextPath (Join-Path ([IO.Directory]::GetParent($codexHome).FullName) '.serena\contexts\codex-file-tools.yml')
        Assert-True ($after -ceq $before) 'manifest CAS 丢失后目标必须零写'
        'Test-CodexFunctionalHookRegistration.ps1 -OnlyRestoreManifestCas: PASS'
        return
    }

    if ($OnlyRestoreBackupSnapshot) {
        $env:CODEX_HOST_HOOK_TEST_RESTORE_BACKUP_AFTER_SNAPSHOT = 'hooks.json'
        try { $restoreRaw = & $scriptPath -Mode Restore -CodexHome $codexHome -EvidencePath $repair.evidencePath -Json }
        finally { Remove-Item Env:CODEX_HOST_HOOK_TEST_RESTORE_BACKUP_AFTER_SNAPSHOT -ErrorAction SilentlyContinue }
        $restore = (($restoreRaw | Out-String).Trim() | ConvertFrom-Json)
        Assert-True ([bool]$restore.ok -and [bool]$restore.changed) 'backup snapshot 后路径换代不得改变已捕获的恢复字节'
        Assert-True ((Get-Sha256 (Join-Path $codexHome 'hooks.json')) -ceq $checkFingerprintBefore[0]) 'Restore action 必须使用同一 snapshot bytes'
        Assert-True ((Get-Sha256 (Join-Path $repair.evidencePath 'hooks.json')) -cne [string]$successManifest.originalHashes.'hooks.json') 'fixture 必须真实制造 backup path 换代'
        'Test-CodexFunctionalHookRegistration.ps1 -OnlyRestoreBackupSnapshot: PASS'
        return
    }

    if ($OnlyRestoreRetirementIrreversibility) {
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $codexHome 'hooks\__pycache__'))) 'Repair 必须先退役 allowlisted legacy 文件，再退役其目录'
        $restoreRaw = & $scriptPath -Mode Restore -CodexHome $codexHome -EvidencePath $repair.evidencePath -Json
        $restore = (($restoreRaw | Out-String).Trim() | ConvertFrom-Json)
        Assert-True ([bool]$restore.ok -and [bool]$restore.changed) 'Restore 必须完成受管资源回滚'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $codexHome 'hooks\__pycache__') -PathType Container)) 'Restore 不得重建已退役 legacy 目录'
        Assert-True (-not (Test-Path -LiteralPath $retiredDirectoryFilePath -PathType Leaf)) 'Restore 不得重建已退役 nested legacy 文件'
        $secondRaw = & $scriptPath -Mode Restore -CodexHome $codexHome -EvidencePath $repair.evidencePath -Json
        $second = (($secondRaw | Out-String).Trim() | ConvertFrom-Json)
        Assert-True ([bool]$second.ok -and -not [bool]$second.changed) '退役资源不可恢复后的第二次 Restore 必须 no-op'
        'Test-CodexFunctionalHookRegistration.ps1 -OnlyRestoreRetirementIrreversibility: PASS'
        return
    }

    if ($OnlyRestoreThirdVersion) {
        [IO.File]::AppendAllText((Join-Path $codexHome 'hooks.json'), "`r`n", [Text.UTF8Encoding]::new($false))
        $fingerprintBeforeBlockedRestore = Get-RestoreTargetFingerprint -CodexHome $codexHome -HostManifest $manifest -EvidenceManifest $successManifest -ContextPath (Join-Path ([IO.Directory]::GetParent($codexHome).FullName) '.serena\contexts\codex-file-tools.yml')
        $restoreFailed = $false
        try { & $scriptPath -Mode Restore -CodexHome $codexHome -EvidencePath $repair.evidencePath -Json | Out-Null } catch { $restoreFailed = $true }
        Assert-True $restoreFailed '第三版本必须使 Restore fail-closed'
        $blockedManifest = Get-Content -LiteralPath (Join-Path $repair.evidencePath 'manifest.json') -Raw | ConvertFrom-Json
        Assert-True ($blockedManifest.status -ceq 'restore-blocked') '第三版本必须记录 restore-blocked'
        Assert-True ((@($blockedManifest.recoveryRequired) -join ',') -ceq 'hooks.json') '第三版本 recoveryRequired 必须精确指向 hooks.json'
        $fingerprintAfterBlockedRestore = Get-RestoreTargetFingerprint -CodexHome $codexHome -HostManifest $manifest -EvidenceManifest $blockedManifest -ContextPath (Join-Path ([IO.Directory]::GetParent($codexHome).FullName) '.serena\contexts\codex-file-tools.yml')
        Assert-True ($fingerprintAfterBlockedRestore -ceq $fingerprintBeforeBlockedRestore) '第三版本完整预检失败后不得修改任何目标'
        'Test-CodexFunctionalHookRegistration.ps1 -OnlyRestoreThirdVersion: PASS'
        return
    }

    if ($OnlyRestoreResume) {
        $previousProgressCount = 0
        $interruptionCount = 0
        while ($true) {
            $env:CODEX_HOST_HOOK_TEST_RESTORE_INTERRUPT_AFTER = '*'
            try { & $scriptPath -Mode Restore -CodexHome $codexHome -EvidencePath $repair.evidencePath -Json | Out-Null } catch {} finally { Remove-Item Env:CODEX_HOST_HOOK_TEST_RESTORE_INTERRUPT_AFTER -ErrorAction SilentlyContinue }
            $resumeManifest = Get-Content -LiteralPath (Join-Path $repair.evidencePath 'manifest.json') -Raw | ConvertFrom-Json
            if ($resumeManifest.status -ceq 'restored') { break }
            Assert-True ($resumeManifest.status -ceq 'restoring') "中断后必须保持 restoring：$($resumeManifest.status)"
            $currentProgressCount = @($resumeManifest.restoreProgress).Count
            Assert-True ($currentProgressCount -eq ($previousProgressCount + 1)) '每次注入只能在一个 restore action 持久化后中断'
            $previousProgressCount = $currentProgressCount
            $interruptionCount++
            Assert-True ($interruptionCount -lt 64) 'Restore action 数量异常或无法续跑'
        }
        Assert-True ($interruptionCount -gt 1) 'Restore 中断测试必须覆盖多个 action'
        Assert-True ((Get-Sha256 (Join-Path $codexHome 'hooks.json')) -ceq $checkFingerprintBefore[0]) '续跑必须恢复原 registry bytes'
        Assert-True ((Get-Sha256 (Join-Path $codexHome '.fixture-user-environment.json')) -ceq $checkFingerprintBefore[1]) '续跑必须恢复原 User 环境 bytes'
        $secondRestoreRaw = & $scriptPath -Mode Restore -CodexHome $codexHome -EvidencePath $repair.evidencePath -Json
        $secondRestore = (($secondRestoreRaw | Out-String).Trim() | ConvertFrom-Json)
        Assert-True ([bool]$secondRestore.ok -and -not [bool]$secondRestore.changed) '续跑完成后的第二次 Restore 必须 no-op'
        'Test-CodexFunctionalHookRegistration.ps1 -OnlyRestoreResume: PASS'
        return
    }

    if ($OnlyRestoreContract) {
        $restoreRaw = & $scriptPath -Mode Restore -CodexHome $codexHome -EvidencePath $repair.evidencePath -Json
        $restore = (($restoreRaw | Out-String).Trim() | ConvertFrom-Json)
        Assert-True ([bool]$restore.ok -and [bool]$restore.changed) 'Restore 必须恢复 completed generation'
        Assert-True ((Get-Sha256 (Join-Path $codexHome 'hooks.json')) -ceq $checkFingerprintBefore[0]) 'Restore 必须恢复原 registry bytes'
        Assert-True ((Get-Sha256 (Join-Path $codexHome '.fixture-user-environment.json')) -ceq $checkFingerprintBefore[1]) 'Restore 必须恢复原 User 环境 bytes'
        foreach ($file in @($manifest.files)) {
            Assert-True (-not (Test-Path -LiteralPath (Join-Path (Join-Path $codexHome 'hooks') $file.liveRelativePath))) "Restore 必须移除本 generation 新增文件：$($file.liveRelativePath)"
        }
        $restoredManifest = Get-Content -LiteralPath (Join-Path $repair.evidencePath 'manifest.json') -Raw | ConvertFrom-Json
        Assert-True ($restoredManifest.status -ceq 'restored') 'Restore 完成后 evidence 必须为 restored'
        $secondRestoreRaw = & $scriptPath -Mode Restore -CodexHome $codexHome -EvidencePath $repair.evidencePath -Json
        $secondRestore = (($secondRestoreRaw | Out-String).Trim() | ConvertFrom-Json)
        Assert-True ([bool]$secondRestore.ok -and -not [bool]$secondRestore.changed) '第二次 Restore 必须严格 no-op'
        'Test-CodexFunctionalHookRegistration.ps1 -OnlyRestoreContract: PASS'
        return
    }

    $registry = Get-Content -LiteralPath (Join-Path $codexHome 'hooks.json') -Raw | ConvertFrom-Json
    Assert-True ([int]$registry.schemaVersion -eq 9 -and $registry.owner -ceq 'unknown-owner-must-survive') 'registry 顶层未知字段必须保留'
    Assert-True (@($registry.hooks.UnknownEvent).Count -eq 1) '未知 event 必须保留'
    $session = @($registry.hooks.SessionStart)
    Assert-True ($session.Count -eq 4) 'SessionStart 必须保留未知组并注册三个受管组'
    Assert-True ($session[0].customGroup -ceq 'unknown-group-must-survive') '未知 SessionStart 组顺序和扩展字段必须保留'
    Assert-True ($session[1].hooks[0].command -ceq 'D:\Codex\.codex\hooks\codex-state-preflight.cmd') 'state preflight identity/order 错误'
    Assert-True ($session[2].matcher -ceq 'startup|resume' -and $session[2].hooks[0].command -ceq 'D:\Codex\.codex\hooks\serena-activation-reminder.cmd') 'activation reminder identity/matcher 错误'
    Assert-True ($session[3].hooks[0].command -ceq 'D:\Codex\.codex\hooks\codex-github-cli-guard.cmd') 'github-cli identity/order 错误'
    Assert-True ($registry.hooks.PreToolUse -is [System.Array]) 'PreToolUse 必须序列化为 matcher group 数组'
    Assert-True ($registry.hooks.Stop -is [System.Array]) 'Stop 必须序列化为 matcher group 数组'
    Assert-True ($registry.hooks.PreToolUse.matcher -ceq 'Bash' -and $registry.hooks.PreToolUse.hooks[0].command -ceq 'D:\Codex\.codex\hooks\serena-reminder-guarded.cmd') 'reminder identity/matcher 错误'
    Assert-True ($registry.hooks.Stop.hooks[0].command -ceq 'D:\Codex\.codex\hooks\serena-cleanup-guarded.cmd') 'cleanup identity 错误'
    Assert-True ([int]$session[1].hooks[0].timeout -eq 10) 'state preflight timeout 必须精确为10秒'
    Assert-True ([int]$session[2].hooks[0].timeout -eq 10) 'activation reminder timeout 必须精确为10秒'
    Assert-True ([int]$session[3].hooks[0].timeout -eq 10) 'github-cli timeout 必须精确为10秒'
    Assert-True ([int]$registry.hooks.PreToolUse.hooks[0].timeout -eq 10) 'Serena reminder timeout 必须精确为10秒'
    Assert-True ([int]$registry.hooks.Stop.hooks[0].timeout -eq 10) 'Serena cleanup timeout 必须精确为10秒'
    $registryText = $registry | ConvertTo-Json -Depth 30 -Compress
    foreach ($retired in @('auto-approve','provider-stability','projectless-root','mobile-permission','serena-dashboard')) {
        Assert-True (-not $registryText.Contains($retired, [System.StringComparison]::OrdinalIgnoreCase)) "退役 identity 不得出现：$retired"
    }

    foreach ($file in @($manifest.files)) {
        $livePath = Join-Path (Join-Path $codexHome 'hooks') $file.liveRelativePath
        $sourcePath = Join-Path $ProjectRoot "managed\codex-hooks\$($file.relativePath)"
        Assert-True (Test-Path -LiteralPath $livePath -PathType Leaf) "缺少发布文件：$($file.liveRelativePath)"
        $sourceRawSha256 = Get-Sha256 $sourcePath
        $sourceCanonicalSha256 = Get-CodexHookManifestSourceSha256 -Path $sourcePath -Name "functional manifest source $($file.relativePath)" -AllowedExactPaths @($sourcePath)
        Assert-True ($sourceCanonicalSha256 -ceq [string]$file.sha256) "host manifest canonical hash 错误：$($file.relativePath)"
        Assert-True ((Get-Sha256 $livePath) -ceq $sourceRawSha256) "发布文件原始字节 hash 错误：$($file.liveRelativePath)"
    }
    foreach ($wrapperName in @('serena-reminder-guarded.cmd','serena-cleanup-guarded.cmd','serena-activation-reminder.cmd')) {
        $wrapper = Get-Content -LiteralPath (Join-Path $codexHome "hooks\$wrapperName") -Raw
        Assert-True ($wrapper.Contains('SERENA_HOME=D:\Codex\.serena', [System.StringComparison]::OrdinalIgnoreCase)) "Serena wrapper 未 pin SERENA_HOME：$wrapperName"
        Assert-True ($wrapper.Contains('pythonw.exe', [System.StringComparison]::OrdinalIgnoreCase) -and $wrapper.Contains('lib\hidden-console-launcher.py', [System.StringComparison]::OrdinalIgnoreCase)) "Serena wrapper 未通过 hidden launcher 启动：$wrapperName"
        Assert-True ($wrapper -notmatch '(?i)https?://|curl|check[-_]?network|check[-_]?auth') "生命周期 wrapper 含网络/认证能力：$wrapperName"
    }
    $stateWrapper = Get-Content -LiteralPath (Join-Path $codexHome 'hooks\codex-state-preflight.cmd') -Raw
    Assert-True ($stateWrapper.Contains([string]$manifest.runtimes.python, [System.StringComparison]::OrdinalIgnoreCase)) 'state wrapper 未固定 manifest 登记的官方 Python'
    Assert-True ($stateWrapper.Contains('pythonw.exe', [System.StringComparison]::OrdinalIgnoreCase) -and $stateWrapper.Contains('lib\hidden-console-launcher.py', [System.StringComparison]::OrdinalIgnoreCase)) 'state wrapper 未通过 hidden launcher 启动'
    Assert-True ($stateWrapper -notmatch '(?i)https?://|curl|check[-_]?network|check[-_]?auth') 'state lifecycle wrapper 含网络/认证能力'

    $stateFixtureParent = Join-Path $ProjectRoot 'reports\codex-state-preflight-test'
    $stateFixtureRoot = Join-Path $stateFixtureParent ([guid]::NewGuid().ToString('N'))
    $stateFixtureHome = Join-Path $stateFixtureRoot 'codex-home'
    $fixtureUtf8 = [System.Text.UTF8Encoding]::new($false)
    New-Item -ItemType Directory -Force -Path $stateFixtureHome | Out-Null
    try {
        [System.IO.File]::WriteAllText((Join-Path $stateFixtureRoot '.codex-state-preflight-fixture'), "codex-state-preflight-test-v1`n", $fixtureUtf8)
        [System.IO.File]::WriteAllText((Join-Path $stateFixtureHome '.codex-global-state.json'), '{"electron-persisted-atom-state":{}}', $fixtureUtf8)
        [System.IO.File]::WriteAllText((Join-Path $stateFixtureHome 'config.toml'), "approval_policy = `"never`"`nsandbox_mode = `"danger-full-access`"`n", $fixtureUtf8)
        $statePolicy = '{"approvalPolicy":"never","sandboxPolicy":{"type":"dangerFullAccess"}}'
        foreach ($name in @('policy.json','state-policy.json')) { [System.IO.File]::WriteAllText((Join-Path $stateFixtureHome $name), $statePolicy, $fixtureUtf8) }
        $sqlitePath = Join-Path $stateFixtureHome 'state_5.sqlite'
        $sqliteSetup = 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("create table threads (id text primary key, source text, thread_source text, approval_mode text, sandbox_policy text, sentinel text)"); c.commit(); c.close()'
        $sqliteSetupResult = Invoke-HiddenChildProcess `
            -FilePath ([string]$manifest.runtimes.python) `
            -ArgumentList @('-I','-S','-B','-X','utf8','-c',$sqliteSetup,$sqlitePath)
        Assert-True ($sqliteSetupResult.exitCode -eq 0) "state preflight SQLite fixture 创建失败：$($sqliteSetupResult.stderr)"
        $stateBefore = @(
            Get-Sha256 (Join-Path $stateFixtureHome '.codex-global-state.json')
            Get-Sha256 $sqlitePath
            Get-Sha256 (Join-Path $stateFixtureHome 'policy.json')
        ) -join '|'
        $stateResult = Invoke-PublicWrapper `
            -Path (Join-Path $codexHome 'hooks\codex-state-preflight.cmd') `
            -InputText '{"session_id":"state-wrapper-fixture"}' `
            -ArgumentList @('--check-only','--json','--fixture-root',$stateFixtureRoot) `
            -Environment @{ HTTP_PROXY = 'http://127.0.0.1:1/no-network'; HTTPS_PROXY = 'http://127.0.0.1:1/no-network'; ALL_PROXY = 'socks5://127.0.0.1:1/no-network' }
        Assert-True ($stateResult.exitCode -eq 0 -and [string]::IsNullOrWhiteSpace($stateResult.stderr)) "deployed state wrapper fixture 必须成功且 stderr 为空：exit=$($stateResult.exitCode), stderr=$($stateResult.stderr)"
        $stateProtocol = $stateResult.stdout | ConvertFrom-Json
        Assert-True ([bool]$stateProtocol.ok -and [bool]$stateProtocol.converged -and [int]$stateProtocol.driftCount -eq 0) 'deployed state wrapper fixture 必须返回已收敛 check-only JSON'
        $stateAfter = @(
            Get-Sha256 (Join-Path $stateFixtureHome '.codex-global-state.json')
            Get-Sha256 $sqlitePath
            Get-Sha256 (Join-Path $stateFixtureHome 'policy.json')
        ) -join '|'
        Assert-True ($stateAfter -ceq $stateBefore) 'deployed state wrapper check-only 不得改写 fixture state/hash'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $stateFixtureRoot 'health') -PathType Container)) 'deployed state wrapper check-only 不得写 health'
    }
    finally {
        if (Test-Path -LiteralPath $stateFixtureRoot) { Remove-Item -LiteralPath $stateFixtureRoot -Recurse -Force }
        if ((Test-Path -LiteralPath $stateFixtureParent -PathType Container) -and @(Get-ChildItem -LiteralPath $stateFixtureParent -Force).Count -eq 0) { Remove-Item -LiteralPath $stateFixtureParent -Force }
    }

    $activationResult = Invoke-PublicWrapper -Path (Join-Path $codexHome 'hooks\serena-activation-reminder.cmd') -InputText '{"session_id":"public-activation"}'
    Assert-True ($activationResult.exitCode -eq 0 -and [string]::IsNullOrWhiteSpace($activationResult.stderr)) "activation public wrapper 必须成功且 stderr 为空：exit=$($activationResult.exitCode), stderr=$($activationResult.stderr)"
    $activationProtocol = $activationResult.stdout | ConvertFrom-Json
    Assert-True ($activationProtocol.hookSpecificOutput.hookEventName -ceq 'SessionStart') 'activation public wrapper 协议错误'
    $sessionA = '{"session_id":"public-session-a","tool_name":"Bash","tool_input":{"command":"rg -n hook file.ps1"}}'
    $sessionB = '{"session_id":"public-session-b","tool_name":"Bash","tool_input":{"command":"rg -n hook file.ps1"}}'
    foreach ($attempt in 1..2) {
        $reminderSilent = Invoke-PublicWrapper -Path (Join-Path $codexHome 'hooks\serena-reminder-guarded.cmd') -InputText $sessionA
        Assert-True ($reminderSilent.exitCode -eq 0 -and [string]::IsNullOrWhiteSpace($reminderSilent.stdout) -and [string]::IsNullOrWhiteSpace($reminderSilent.stderr)) "reminder public wrapper 第${attempt}次必须静默成功"
    }
    $otherSession = Invoke-PublicWrapper -Path (Join-Path $codexHome 'hooks\serena-reminder-guarded.cmd') -InputText $sessionB
    Assert-True ($otherSession.exitCode -eq 0 -and [string]::IsNullOrWhiteSpace($otherSession.stdout)) 'reminder session 隔离失败'
    $reminderThird = Invoke-PublicWrapper -Path (Join-Path $codexHome 'hooks\serena-reminder-guarded.cmd') -InputText $sessionA
    Assert-True ($reminderThird.exitCode -eq 0 -and ($reminderThird.stdout | ConvertFrom-Json).hookSpecificOutput.permissionDecision -ceq 'deny') 'reminder public wrapper 第三次必须输出 deny 协议'
    $cleanupResult = Invoke-PublicWrapper -Path (Join-Path $codexHome 'hooks\serena-cleanup-guarded.cmd') -InputText '{"session_id":"public-session-a"}'
    Assert-True ($cleanupResult.exitCode -eq 0 -and [string]::IsNullOrWhiteSpace($cleanupResult.stdout) -and [string]::IsNullOrWhiteSpace($cleanupResult.stderr)) 'cleanup public wrapper 必须静默成功'
    $sessionAAfterCleanup = Invoke-PublicWrapper -Path (Join-Path $codexHome 'hooks\serena-reminder-guarded.cmd') -InputText $sessionA
    Assert-True ($sessionAAfterCleanup.exitCode -eq 0 -and [string]::IsNullOrWhiteSpace($sessionAAfterCleanup.stdout)) 'cleanup 后 session A 必须从首次静默计数重新开始'
    $sessionBSecond = Invoke-PublicWrapper -Path (Join-Path $codexHome 'hooks\serena-reminder-guarded.cmd') -InputText $sessionB
    $sessionBThird = Invoke-PublicWrapper -Path (Join-Path $codexHome 'hooks\serena-reminder-guarded.cmd') -InputText $sessionB
    Assert-True ([string]::IsNullOrWhiteSpace($sessionBSecond.stdout) -and ($sessionBThird.stdout | ConvertFrom-Json).hookSpecificOutput.permissionDecision -ceq 'deny') 'cleanup session A 不得重置 session B 计数'
    Assert-True ((Get-Content -LiteralPath (Join-Path $codexHome 'hooks\unknown-preserve.txt') -Raw) -ceq 'unknown-live-file-must-survive') '未知 live 文件必须逐字节保留'
    $fixtureEnv = Get-Content -LiteralPath (Join-Path $codexHome '.fixture-user-environment.json') -Raw | ConvertFrom-Json
    Assert-True ($fixtureEnv.SERENA_HOME -ceq 'D:\Codex\.serena') 'fixture User SERENA_HOME 未收敛'
    Assert-True ([Environment]::GetEnvironmentVariable('SERENA_HOME', 'User') -ceq $realSerenaHomeBefore) 'fixture 不得修改真实 User 环境'

    $noop = Invoke-Reconciler -ScriptPath $scriptPath -Mode Repair -CodexHome $codexHome
    Assert-True ([bool]$noop.ok -and -not [bool]$noop.changed -and $null -eq $noop.evidencePath) '第二次 Repair 必须严格 no-op'
    foreach ($file in @($manifest.files)) {
        Assert-True ((Get-Sha256 (Join-Path $ProjectRoot "managed\codex-hooks\$($file.relativePath)")) -ceq $sourceHashesBefore[$file.relativePath]) "Repair 不得修改 managed source：$($file.relativePath)"
    }

    foreach ($phase in @('managed', 'environment', 'registry')) {
        $failureHome = Join-Path $testRoot "$phase\.codex"
        New-FunctionalHookFixture -CodexHome $failureHome
        $beforeRegistryHash = Get-Sha256 (Join-Path $failureHome 'hooks.json')
        $env:CODEX_HOST_HOOK_TEST_POST_COMMIT_FAILURE = $phase
        $failed = $false
        try {
            & $scriptPath -Mode Repair -CodexHome $failureHome -Json | Out-Null
        } catch {
            $failed = $true
        } finally {
            Remove-Item Env:CODEX_HOST_HOOK_TEST_POST_COMMIT_FAILURE -ErrorAction SilentlyContinue
        }
        Assert-True $failed "故障 seam 必须使 Repair 失败：$phase"
        Assert-True ((Get-Sha256 (Join-Path $failureHome 'hooks.json')) -ceq $beforeRegistryHash) "故障后 registry 必须恢复：$phase"
        $failureEnv = Get-Content -LiteralPath (Join-Path $failureHome '.fixture-user-environment.json') -Raw | ConvertFrom-Json
        Assert-True ($failureEnv.SERENA_HOME -ceq 'D:\hermes-data\.serena') "故障后环境必须恢复：$phase"
        foreach ($file in @($manifest.files)) {
            Assert-True (-not (Test-Path -LiteralPath (Join-Path (Join-Path $failureHome 'hooks') $file.liveRelativePath))) "故障后新增文件必须移除：$phase / $($file.liveRelativePath)"
        }
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $failureHome 'hooks\lib'))) "故障后本次创建的空目录必须移除：$phase"
        $failureEvidence = @(Get-ChildItem -LiteralPath (Join-Path $failureHome 'run-evidence\host-hook-remediation') -Directory)
        Assert-True ($failureEvidence.Count -eq 1) "故障 evidence 必须唯一：$phase"
        $failureManifest = Get-Content -LiteralPath (Join-Path $failureEvidence[0].FullName 'manifest.json') -Raw | ConvertFrom-Json
        Assert-True ($failureManifest.status -ceq 'rolled-back') "故障必须记录完整回滚：$phase"
    }

    $ancestorHome = Join-Path $testRoot 'managed-ancestor\.codex'
    $ancestorParent = Join-Path $ancestorHome 'hooks\lib'
    $ancestorMoved = "$ancestorParent.fixture-moved"
    $externalParent = Join-Path $testRoot 'outside-managed'
    New-FunctionalHookFixture -CodexHome $ancestorHome
    New-Item -ItemType Directory -Force -Path $ancestorParent, $externalParent | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $ancestorParent 'sentinel.txt'), 'managed-parent-sentinel', $fixtureUtf8)
    [System.IO.File]::WriteAllText((Join-Path $externalParent 'sentinel.txt'), 'outside-sentinel', $fixtureUtf8)
    $ancestorRegistryBefore = Get-Sha256 (Join-Path $ancestorHome 'hooks.json')
    $ancestorEnvironmentBefore = Get-Sha256 (Join-Path $ancestorHome '.fixture-user-environment.json')
    $externalBefore = Get-Sha256 (Join-Path $externalParent 'sentinel.txt')
    $env:CODEX_HOST_HOOK_TEST_MANAGED_PARENT_ATTACK = ([ordered]@{
        targetParent = $ancestorParent
        externalParent = $externalParent
    } | ConvertTo-Json -Compress)
    $ancestorFailed = $false
    try {
        & $scriptPath -Mode Repair -CodexHome $ancestorHome -Json | Out-Null
    } catch {
        $ancestorFailed = $true
    } finally {
        Remove-Item Env:CODEX_HOST_HOOK_TEST_MANAGED_PARENT_ATTACK -ErrorAction SilentlyContinue
    }
    try {
        Assert-True $ancestorFailed 'managed ancestor 在最终发布前被替换时 Repair 必须失败'
        Assert-True ((Get-Sha256 (Join-Path $externalParent 'sentinel.txt')) -ceq $externalBefore) 'managed ancestor 攻击不得改写授权根外原文件'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $externalParent 'CodexHookRuntime.ps1'))) 'managed ancestor 攻击不得在授权根外创建受管文件'
        Assert-True ((Get-Sha256 (Join-Path $ancestorHome 'hooks.json')) -ceq $ancestorRegistryBefore) 'managed ancestor 攻击后 registry 必须保持原字节'
        Assert-True ((Get-Sha256 (Join-Path $ancestorHome '.fixture-user-environment.json')) -ceq $ancestorEnvironmentBefore) 'managed ancestor 攻击后 User 环境 fixture 必须保持原字节'
        Assert-True ((Get-Content -LiteralPath (Join-Path $ancestorHome 'hooks\unknown-preserve.txt') -Raw) -ceq 'unknown-live-file-must-survive') 'managed ancestor 攻击后未知 live 文件必须保持原字节'
        Assert-True ((Get-Content -LiteralPath (Join-Path $ancestorParent 'sentinel.txt') -Raw) -ceq 'managed-parent-sentinel') 'managed ancestor 攻击后原目录内容必须保持'
        $ancestorParentItem = Get-Item -LiteralPath $ancestorParent -Force
        Assert-True ($ancestorParentItem.PSIsContainer -and ($ancestorParentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'managed ancestor 攻击后目标父目录必须仍是普通目录'
        Assert-True (-not (Test-Path -LiteralPath $ancestorMoved)) 'managed ancestor 攻击不得遗留 moved parent'
        Assert-True (@(Get-ChildItem -LiteralPath $externalParent -Force -Recurse).Count -eq 1) 'managed ancestor 攻击不得在授权根外遗留文件或临时文件'
        foreach ($file in @($manifest.files)) {
            $ancestorManagedPath = Join-Path (Join-Path $ancestorHome 'hooks') $file.liveRelativePath
            Assert-True (-not (Test-Path -LiteralPath $ancestorManagedPath)) "managed ancestor 攻击后受管目标必须恢复 missing：$($file.liveRelativePath)"
            Assert-True ((Get-Sha256 (Join-Path $ProjectRoot "managed\codex-hooks\$($file.relativePath)")) -ceq $sourceHashesBefore[$file.relativePath]) "managed ancestor 攻击不得改写 managed source：$($file.relativePath)"
        }
        Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $ancestorHome 'hooks') -Filter '.codex-hook-*.tmp' -Force -Recurse).Count -eq 0) 'managed ancestor 攻击不得遗留 atomic temp'
        $ancestorEvidence = @(Get-ChildItem -LiteralPath (Join-Path $ancestorHome 'run-evidence\host-hook-remediation') -Directory)
        Assert-True ($ancestorEvidence.Count -eq 1) 'managed ancestor 攻击 evidence 必须唯一'
        $ancestorManifest = Get-Content -LiteralPath (Join-Path $ancestorEvidence[0].FullName 'manifest.json') -Raw | ConvertFrom-Json
        $ancestorRollbackErrors = if ($ancestorManifest.PSObject.Properties.Name -ccontains 'rollbackErrors') { @($ancestorManifest.rollbackErrors) -join '; ' } else { '' }
        $ancestorRollbackErrorCount = if ($ancestorManifest.PSObject.Properties.Name -ccontains 'rollbackErrors') { @($ancestorManifest.rollbackErrors).Count } else { 0 }
        Assert-True ($ancestorManifest.status -ceq 'rolled-back') "managed ancestor 攻击必须完整回滚：status=$($ancestorManifest.status); error=$($ancestorManifest.error); rollbackErrors=$ancestorRollbackErrors"
        Assert-True ($ancestorRollbackErrorCount -eq 0) "managed ancestor 攻击不得有 rollbackErrors：$ancestorRollbackErrors"
    } finally {
        if ((Test-Path -LiteralPath $ancestorParent) -and ((Get-Item -LiteralPath $ancestorParent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            $ancestorCleanupResult = Invoke-HiddenChildProcess -FilePath 'C:\Windows\System32\cmd.exe' -ArgumentList @('/d','/c','rmdir',$ancestorParent)
            Assert-True ($ancestorCleanupResult.exitCode -eq 0) "managed ancestor fixture junction 删除失败：$($ancestorCleanupResult.stderr)"
        }
        if ((Test-Path -LiteralPath $ancestorMoved -PathType Container) -and -not (Test-Path -LiteralPath $ancestorParent)) {
            Move-Item -LiteralPath $ancestorMoved -Destination $ancestorParent
        }
    }

    $legacyHome = Join-Path $testRoot 'legacy-delete\.codex'
    $legacyPath = Join-Path $legacyHome 'hooks\codex-mobile-permission-guard.cmd'
    New-FunctionalHookFixture -CodexHome $legacyHome
    [IO.File]::WriteAllText($legacyPath, 'approved-legacy-bytes', $fixtureUtf8)
    $replacementContent = 'third-party-replacement-must-survive'
    $env:CODEX_HOST_HOOK_TEST_LEGACY_DELETE_REPLACE = ([ordered]@{
        targetPath = $legacyPath
        replacementContent = $replacementContent
    } | ConvertTo-Json -Compress)
    $legacyFailed = $false
    $legacyFailureMessage = ''
    try {
        & $scriptPath -Mode Repair -CodexHome $legacyHome -Json | Out-Null
    } catch {
        $legacyFailed = $true
        $legacyFailureMessage = $_.Exception.Message
    } finally {
        Remove-Item Env:CODEX_HOST_HOOK_TEST_LEGACY_DELETE_REPLACE -ErrorAction SilentlyContinue
    }
    try {
        Assert-True $legacyFailed 'legacy 校验后被第三方替换时 Repair 必须失败'
        $legacyEvidenceForError = @(Get-ChildItem -LiteralPath (Join-Path $legacyHome 'run-evidence\host-hook-remediation') -Directory | Sort-Object Name)[-1]
        $legacyEvidenceManifest = Get-Content -LiteralPath (Join-Path $legacyEvidenceForError.FullName 'manifest.json') -Raw | ConvertFrom-Json
        Assert-True (Test-Path -LiteralPath $legacyPath -PathType Leaf) 'legacy 条件删除不得删除第三方替换文件'
        $legacyActual = Get-Content -LiteralPath $legacyPath -Raw
        Assert-True ($legacyActual -ceq $replacementContent) "legacy 条件删除必须逐字节保留第三方替换内容：actual=$legacyActual; error=$legacyFailureMessage; manifestError=$($legacyEvidenceManifest.error)"
    } finally {}

    $hardlinkHome = Join-Path $testRoot 'legacy-hardlink\.codex'
    $hardlinkSource = Join-Path $testRoot 'legacy-hardlink-source.txt'
    $hardlinkPath = Join-Path $hardlinkHome 'hooks\codex-mobile-permission-guard.cmd'
    New-FunctionalHookFixture -CodexHome $hardlinkHome
    [IO.File]::WriteAllText($hardlinkSource, 'hardlink-source-must-survive', $fixtureUtf8)
    New-Item -ItemType HardLink -Path $hardlinkPath -Target $hardlinkSource | Out-Null
    $hardlinkFailed = $false
    try { & $scriptPath -Mode Repair -CodexHome $hardlinkHome -Json | Out-Null } catch { $hardlinkFailed = $true }
    Assert-True $hardlinkFailed 'legacy hardlink 必须在退役前 fail-closed'
    Assert-True ((Get-Content -LiteralPath $hardlinkSource -Raw) -ceq 'hardlink-source-must-survive') 'legacy hardlink 拒绝不得改变链接目标 bytes'
    Assert-True (Test-Path -LiteralPath $hardlinkPath -PathType Leaf) 'legacy hardlink 拒绝不得删除 hardlink'

    $reparseHome = Join-Path $testRoot 'legacy-reparse\.codex'
    $reparsePath = Join-Path $reparseHome 'hooks\__pycache__'
    $reparseExternal = Join-Path $testRoot 'legacy-reparse-external'
    New-FunctionalHookFixture -CodexHome $reparseHome
    New-Item -ItemType Directory -Force -Path $reparseExternal | Out-Null
    [IO.File]::WriteAllText((Join-Path $reparseExternal 'sentinel.txt'), 'reparse-target-must-survive', $fixtureUtf8)
    $reparseCreateResult = Invoke-HiddenChildProcess -FilePath 'C:\Windows\System32\cmd.exe' -ArgumentList @('/d','/c','mklink','/J',$reparsePath,$reparseExternal)
    Assert-True ($reparseCreateResult.exitCode -eq 0) "legacy reparse fixture junction 创建失败：$($reparseCreateResult.stderr)"
    try {
        $reparseFailed = $false
        try { & $scriptPath -Mode Repair -CodexHome $reparseHome -Json | Out-Null } catch { $reparseFailed = $true }
        Assert-True $reparseFailed 'legacy reparse directory 必须在退役前 fail-closed'
        Assert-True ((Get-Content -LiteralPath (Join-Path $reparseExternal 'sentinel.txt') -Raw) -ceq 'reparse-target-must-survive') 'legacy reparse 拒绝不得改变外部目标 bytes'
    } finally {
        if ((Test-Path -LiteralPath $reparsePath) -and ((Get-Item -LiteralPath $reparsePath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            $reparseCleanupResult = Invoke-HiddenChildProcess -FilePath 'C:\Windows\System32\cmd.exe' -ArgumentList @('/d','/c','rmdir',$reparsePath)
            Assert-True ($reparseCleanupResult.exitCode -eq 0) "legacy reparse fixture junction 删除失败：$($reparseCleanupResult.stderr)"
        }
    }

    $postPhases = if ([string]::IsNullOrWhiteSpace($OnlyPostPhase)) { @('acl','legacy','final') } else { @($OnlyPostPhase) }
    if ($OnlyPostCleanupReplace -and (@($postPhases | Where-Object { $_ -notin @('acl','final') }).Count -gt 0)) {
        throw '-OnlyPostCleanupReplace 只允许与 -OnlyPostPhase acl/final 配合'
    }
    foreach ($postPhase in $postPhases) {
        $postHome = Join-Path $testRoot "post-$postPhase\.codex"
        New-FunctionalHookFixture -CodexHome $postHome
        $postLegacyPath = Join-Path $postHome 'hooks\codex-mobile-permission-guard.cmd'
        [IO.File]::WriteAllText($postLegacyPath, "legacy-before-$postPhase", $fixtureUtf8)
        $postNestedLegacyPath = Join-Path $postHome 'hooks\__pycache__\codex-mobile-permission-guard.cpython-313.pyc'
        New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($postNestedLegacyPath)) | Out-Null
        [IO.File]::WriteAllText($postNestedLegacyPath, "nested-legacy-before-$postPhase", $fixtureUtf8)
        $postContextPath = Join-Path ([IO.Directory]::GetParent($postHome).FullName) '.serena\contexts\codex-file-tools.yml'
        $postTrackedPaths = @(
            (Join-Path $postHome 'config.toml'),
            (Join-Path $postHome 'hooks.json'),
            (Join-Path $postHome '.fixture-user-environment.json'),
            (Join-Path $postHome 'hooks\unknown-preserve.txt'),
            $postContextPath
        )
        $postHashesBefore = [ordered]@{}
        foreach ($postPath in $postTrackedPaths) { $postHashesBefore[$postPath] = Get-Sha256 $postPath }
        $postAclPaths = @((Join-Path $postHome 'hooks'), (Join-Path $postHome 'hooks\unknown-preserve.txt'), $postContextPath)
        $postAclsBefore = [ordered]@{}
        foreach ($postAclPath in $postAclPaths) { $postAclsBefore[$postAclPath] = (Get-Acl -LiteralPath $postAclPath).Sddl }
        $postCleanupTarget = Join-Path $postHome 'hooks\lib'
        $postCleanupMoved = "$postCleanupTarget.fixture-cleanup-moved"
        $postCleanupExternal = Join-Path $testRoot "post-$postPhase-cleanup-external"
        $postCleanupExternalHash = $null
        if ($OnlyPostCleanupReplace) {
            New-Item -ItemType Directory -Force -Path $postCleanupExternal | Out-Null
            [IO.File]::WriteAllText((Join-Path $postCleanupExternal 'third-party-sentinel.txt'), "third-party-post-$postPhase", $fixtureUtf8)
            $postCleanupExternalHash = Get-Sha256 (Join-Path $postCleanupExternal 'third-party-sentinel.txt')
            $env:CODEX_HOST_HOOK_TEST_CREATED_DIRECTORY_CLEANUP_REPLACE = ([ordered]@{
                targetParent = $postCleanupTarget
                externalParent = $postCleanupExternal
            } | ConvertTo-Json -Compress)
        }
        $env:CODEX_HOST_HOOK_TEST_POST_COMMIT_FAILURE = $postPhase
        $postFailed = $false
        try { & $scriptPath -Mode Repair -CodexHome $postHome -Json | Out-Null } catch { $postFailed = $true } finally {
            Remove-Item Env:CODEX_HOST_HOOK_TEST_POST_COMMIT_FAILURE -ErrorAction SilentlyContinue
            Remove-Item Env:CODEX_HOST_HOOK_TEST_CREATED_DIRECTORY_CLEANUP_REPLACE -ErrorAction SilentlyContinue
        }
        Assert-True $postFailed "post-commit $postPhase seam 必须使 Repair 失败"
        foreach ($postPath in $postTrackedPaths) {
            Assert-True (Test-Path -LiteralPath $postPath -PathType Leaf) "post-commit $postPhase rollback 缺少原文件：$postPath"
            Assert-True ((Get-Sha256 $postPath) -ceq $postHashesBefore[$postPath]) "post-commit $postPhase rollback 未恢复原 bytes：$postPath"
        }
        foreach ($file in @($manifest.files)) {
            Assert-True (-not (Test-Path -LiteralPath (Join-Path (Join-Path $postHome 'hooks') $file.liveRelativePath))) "post-commit $postPhase rollback 未移除新增 managed 文件：$($file.liveRelativePath)"
        }
        if ($OnlyPostCleanupReplace) {
            Assert-True (Test-Path -LiteralPath $postCleanupMoved -PathType Container) "post-commit $postPhase cleanup 不得删除 moved 原目录 identity"
            Assert-True (Test-Path -LiteralPath $postCleanupTarget -PathType Container) "post-commit $postPhase cleanup 不得删除第三方替代入口"
            Assert-True (((Get-Item -LiteralPath $postCleanupTarget -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) "post-commit $postPhase fixture 必须真实建立替代 junction"
            Assert-True ((Get-Sha256 (Join-Path $postCleanupExternal 'third-party-sentinel.txt')) -ceq $postCleanupExternalHash) "post-commit $postPhase cleanup 不得改写替代目录内容"
        } else {
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $postHome 'hooks\lib'))) "post-commit $postPhase rollback 未移除新增 managed 目录"
        }
        foreach ($postAclPath in $postAclPaths) {
            Assert-True ((Get-Acl -LiteralPath $postAclPath).Sddl -ceq $postAclsBefore[$postAclPath]) "post-commit $postPhase rollback 未恢复原 ACL：$postAclPath"
        }
        $postEvidence = @(Get-ChildItem -LiteralPath (Join-Path $postHome 'run-evidence\host-hook-remediation') -Directory)
        Assert-True ($postEvidence.Count -eq 1) "post-commit $postPhase evidence 必须唯一"
        $postManifest = Get-Content -LiteralPath (Join-Path $postEvidence[0].FullName 'manifest.json') -Raw | ConvertFrom-Json
        $postRecoveryRequired = if ($postManifest.PSObject.Properties.Name -ccontains 'recoveryRequired') { @($postManifest.recoveryRequired) -join ',' } else { '' }
        $postRollbackErrors = if ($postManifest.PSObject.Properties.Name -ccontains 'rollbackErrors') { @($postManifest.rollbackErrors) -join ';' } else { '' }
        if ($OnlyPostCleanupReplace) {
            Assert-True ($postManifest.status -ceq 'unsafe-partial') "post-commit $postPhase cleanup identity 漂移必须 unsafe-partial：status=$($postManifest.status)"
            Assert-True (@($postManifest.rollbackErrors).Count -eq 1) "post-commit $postPhase cleanup identity 漂移必须精确一条 rollback error"
            Assert-True (@($postManifest.recoveryRequired).Count -eq 1 -and [string]$postManifest.recoveryRequired[0] -clike 'managed-directory:*') "post-commit $postPhase cleanup 必须给出精确 recoveryRequired"
            if ((Test-Path -LiteralPath $postCleanupTarget) -and ((Get-Item -LiteralPath $postCleanupTarget -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                $postCleanupResult = Invoke-HiddenChildProcess -FilePath 'C:\Windows\System32\cmd.exe' -ArgumentList @('/d','/c','rmdir',$postCleanupTarget)
                Assert-True ($postCleanupResult.exitCode -eq 0) "post-commit $postPhase fixture junction 删除失败：$($postCleanupResult.stderr)"
            }
            if ((Test-Path -LiteralPath $postCleanupMoved -PathType Container) -and -not (Test-Path -LiteralPath $postCleanupTarget)) {
                Move-Item -LiteralPath $postCleanupMoved -Destination $postCleanupTarget
            }
        } else {
            $expectedStatus = if ($postPhase -eq 'acl') { 'rolled-back' } else { 'unsafe-partial' }
            Assert-True ($postManifest.status -ceq $expectedStatus) "post-commit $postPhase 状态错误：status=$($postManifest.status); recoveryRequired=$postRecoveryRequired; rollbackErrors=$postRollbackErrors"
            if ($postPhase -eq 'acl') {
                Assert-True (Test-Path -LiteralPath $postLegacyPath -PathType Leaf) 'ACL phase 失败不应提前退役 legacy 文件'
                Assert-True (Test-Path -LiteralPath $postNestedLegacyPath -PathType Leaf) 'ACL phase 失败不应提前退役 nested legacy 文件'
            } elseif ($postPhase -eq 'legacy') {
                Assert-True (-not (Test-Path -LiteralPath $postLegacyPath -PathType Leaf)) 'legacy phase 不得复活首个已退役文件'
                Assert-True (Test-Path -LiteralPath $postNestedLegacyPath -PathType Leaf) 'legacy phase 不得删除后续 nested legacy 文件'
            } else {
                Assert-True (-not (Test-Path -LiteralPath $postLegacyPath -PathType Leaf)) 'final phase 不得复活已退役 legacy 文件'
                Assert-True (-not (Test-Path -LiteralPath $postNestedLegacyPath -PathType Leaf)) 'final phase 不得复活已退役 nested legacy 文件'
            }
        }
    }
    'Test-CodexFunctionalHookRegistration.ps1: PASS'
} finally {
    Assert-True ([Environment]::GetEnvironmentVariable('SERENA_HOME', 'User') -ceq $realSerenaHomeBefore) '测试结束时真实 User SERENA_HOME 漂移'
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
