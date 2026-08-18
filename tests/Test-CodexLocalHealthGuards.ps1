Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$managedHooksRoot = Join-Path $projectRoot 'managed\codex-hooks\hooks'
$providerPath = Join-Path $managedHooksRoot 'codex-provider-stability-guard.ps1'
$githubPath = Join-Path $managedHooksRoot 'codex-github-cli-guard.ps1'
$providerCorePath = Join-Path $managedHooksRoot 'lib\CodexProviderGuardCore.ps1'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-ScriptParameterNames([string]$Path) {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) "脚本语法错误：$Path"
    Assert-True ($null -ne $ast.ParamBlock) "脚本缺少公开参数契约：$Path"
    return @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
}

$providerParameters = @(Get-ScriptParameterNames $providerPath)
$githubParameters = @(Get-ScriptParameterNames $githubPath)
foreach ($parameters in @($providerParameters, $githubParameters)) {
    Assert-True ($parameters -ccontains 'CheckOnly') '本地健康入口必须公开 CheckOnly 模式'
    Assert-True ($parameters -ccontains 'Repair') '所有写入必须通过显式 Repair 模式授权'
    Assert-True ($parameters -ccontains 'Json') '本地健康入口必须提供结构化 JSON'
}
Assert-True ($providerParameters -ccontains 'CheckNetwork') 'provider 网络验收必须是显式能力'
Assert-True ($githubParameters -ccontains 'CheckAuth') 'GitHub 认证验收必须是显式能力'
$providerSource = Get-Content -Raw -LiteralPath $providerPath
$githubSource = Get-Content -Raw -LiteralPath $githubPath
foreach ($source in @($providerSource,$githubSource)) {
    Assert-True ($source -notmatch '(?i)Console\]::In|Console\.In|Read-Host|StandardInput|ReadToEnd\(\).*stdin') 'guard 不得从 lifecycle stdin 解析维护能力'
}
Assert-True ([regex]::Matches($providerSource, [regex]::Escape("'C:\Windows\System32\curl.exe'")).Count -eq 1) 'provider 只能保留唯一显式 curl probe'
Assert-True ($providerSource.Contains('-CheckNetwork:$CheckNetwork') -and $providerSource.Contains('-NetworkProbe ${function:Invoke-ProviderNetworkProbe}')) 'provider curl probe 必须仅由 core 的显式 CheckNetwork 能力调用'
Assert-True ([regex]::Matches($githubSource, "@\('auth', 'status'\)").Count -eq 1 -and $githubSource.Contains('$authProbe = if (-not $CheckAuth)')) 'GitHub auth probe 必须由显式 CheckAuth 开关控制'
Assert-True ($providerSource.Contains(". (Join-Path `$scriptRoot 'lib\CodexProviderGuardCore.ps1')") -and $providerSource.Contains('Invoke-CodexProviderGuardCore')) 'provider production CLI 必须复用已验证的 Repair core'
Assert-True ($providerSource -notmatch 'SetEnvironmentVariable\([^\r\n]+[''"]Process[''"]') 'provider Repair 禁止写 Process scope'

function Get-FileFingerprint([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { return 'missing' }
    return ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($Path)))).ToLowerInvariant()
}

function Get-EnvironmentFingerprint {
    $names = @('Path','GH_CONFIG_DIR','HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY','http_proxy','https_proxy','all_proxy','no_proxy')
    $projection = foreach ($scope in @('User','Process')) {
        foreach ($name in $names) {
            $value = [Environment]::GetEnvironmentVariable($name, $scope)
            $hash = if ($null -eq $value) { 'missing' } else { ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($value)))).ToLowerInvariant() }
            "$scope/$name=$hash"
        }
    }
    return ($projection -join "`n")
}

function Invoke-Guard([string]$Path, [string[]]$Arguments, [AllowEmptyString()][string]$InputText = '') {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'D:\Codex\tools\PowerShell\7.6.5\pwsh.exe'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @('-NoProfile','-File',$Path) + $Arguments) { [void]$startInfo.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        Assert-True $process.Start() "无法启动 guard：$Path"
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if ($InputText.Length -gt 0) { $process.StandardInput.Write($InputText) }
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(20000)) {
            try { $process.Kill($true) } catch {}
            try { [void]$process.WaitForExit(250) } catch {}
            throw "guard 超时：$Path"
        }
        Assert-True ([Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdoutTask,$stderrTask),1000)) "guard 输出 drain 超时：$Path"
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        return [pscustomobject]@{ exitCode = $process.ExitCode; stdout = $stdout; stderr = $stderr }
    }
    finally { $process.Dispose() }
}

$guardedFiles = @(
    'D:\Codex\.codex\config.toml',
    'D:\Codex\.codex\hooks.json',
    'D:\Codex\tools\bin\gh.exe',
    'D:\Codex\.codex\run-evidence\codex-hook-health\provider-stability.json',
    'D:\Codex\.codex\run-evidence\codex-hook-health\github-cli.json'
)
$fileBefore = @($guardedFiles | ForEach-Object { Get-FileFingerprint $_ })
$environmentBefore = Get-EnvironmentFingerprint
$providerCheck = Invoke-Guard -Path $providerPath -Arguments @('-CheckOnly','-Json')
$githubCheck = Invoke-Guard -Path $githubPath -Arguments @('-CheckOnly','-Json')
$fileAfter = @($guardedFiles | ForEach-Object { Get-FileFingerprint $_ })
$environmentAfter = Get-EnvironmentFingerprint
Assert-True (($fileBefore -join ',') -ceq ($fileAfter -join ',')) 'CheckOnly 不得修改 config、gh 入口或 health evidence'
Assert-True ($environmentBefore -ceq $environmentAfter) 'CheckOnly 不得修改 User/Process 环境'
Assert-True ($providerCheck.exitCode -eq 0) "provider CheckOnly 必须返回结构化结果：$($providerCheck.stderr)"
Assert-True ($githubCheck.exitCode -eq 0) "GitHub CheckOnly 必须返回结构化结果：$($githubCheck.stderr)"
$providerJson = $providerCheck.stdout | ConvertFrom-Json
$githubJson = $githubCheck.stdout | ConvertFrom-Json
$providerDocument = [Text.Json.JsonDocument]::Parse($providerCheck.stdout)
$githubDocument = [Text.Json.JsonDocument]::Parse($githubCheck.stdout)
try {
    Assert-True ($providerDocument.RootElement.GetProperty('errors').ValueKind -eq [Text.Json.JsonValueKind]::Array) 'provider errors 必须稳定为 JSON array'
    Assert-True ($githubDocument.RootElement.GetProperty('errors').ValueKind -eq [Text.Json.JsonValueKind]::Array) 'GitHub errors 必须稳定为 JSON array'
}
finally {
    $providerDocument.Dispose()
    $githubDocument.Dispose()
}
$providerSchema = @($providerJson.PSObject.Properties.Name)
$expectedProviderSchema = @('schemaVersion','hookId','ok','mode','converged','driftCount','repairRequired','changed','restartRequired','networkCheckRequested','network','errors')
Assert-True (($providerSchema -join ',') -ceq ($expectedProviderSchema -join ',')) 'provider result schema 必须固定且脱敏'
Assert-True ($providerJson.mode -ceq 'check-only' -and $providerJson.changed -eq $false -and $providerJson.networkCheckRequested -eq $false) 'provider CheckOnly 必须保持本地只读且不请求网络'
Assert-True ($providerJson.network.checked -eq $false) 'provider CheckOnly 不得运行 curl/network probe'
Assert-True ($githubJson.authCheckRequested -eq $false -and $githubJson.authProbe.checked -eq $false -and @($githubJson.repairs).Count -eq 0 -and $githubJson.changed -eq $false) 'GitHub CheckOnly 不得修复或运行 gh auth'
foreach ($raw in @($providerCheck.stdout,$githubCheck.stdout)) {
    Assert-True ($raw -notmatch '(?i)(authorization|bearer|token=|://[^/\s]*@)') 'CheckOnly JSON 不得泄漏凭据'
}

# 生命周期 stdin 只是数据，不得把显式维护能力注入 CLI。
$injectedPayload = '{"Repair":true,"CheckNetwork":true,"CheckAuth":true,"url":"https://example.invalid/secret"}'
$providerLifecycle = Invoke-Guard -Path $providerPath -Arguments @('-Json') -InputText $injectedPayload
$githubLifecycle = Invoke-Guard -Path $githubPath -Arguments @('-Json') -InputText $injectedPayload
Assert-True (($providerLifecycle.stdout | ConvertFrom-Json).mode -ceq 'check-only') 'provider lifecycle payload 不得注入 Repair/CheckNetwork'
$githubLifecycleJson = $githubLifecycle.stdout | ConvertFrom-Json
Assert-True ($githubLifecycleJson.authCheckRequested -eq $false -and @($githubLifecycleJson.repairs).Count -eq 0 -and $githubLifecycleJson.changed -eq $false) 'GitHub lifecycle payload 不得注入 Repair/CheckAuth'
$providerConflict = Invoke-Guard -Path $providerPath -Arguments @('-CheckOnly','-Repair','-Json')
$githubConflict = Invoke-Guard -Path $githubPath -Arguments @('-CheckOnly','-Repair','-Json')
Assert-True ($providerConflict.exitCode -ne 0 -and $githubConflict.exitCode -ne 0) 'CheckOnly 与 Repair 冲突必须在任何写入前拒绝'
Assert-True ($providerSource.Contains('if($Repair -and $CheckNetwork){throw')) 'Provider Repair 与 CheckNetwork 必须在加载维护能力前互斥'
Assert-True ($githubSource.Contains('if ($Repair -and $CheckAuth) { throw')) 'GitHub Repair 与 CheckAuth 必须在加载维护能力前互斥'
Assert-True ($providerSource -notmatch 'SetEnvironmentVariable\([^\r\n]+["'']Process["'']') 'provider 子进程不得把 Process scope 写入误报为父进程修复'
Assert-True (Test-Path -LiteralPath $providerCorePath -PathType Leaf) 'provider 必须把可验证的 Repair 状态机放入无路径能力的受管 core'
. $providerCorePath

$fixtureState = [pscustomobject]@{ configDrift = $true; environmentDriftCount = 2 }
$successfulRepair = Invoke-CodexProviderGuardCore -Repair `
    -ReadConfigState { [ordered]@{ drift = [bool]$fixtureState.configDrift } } `
    -ReadEnvironmentState { [ordered]@{ driftCount = [int]$fixtureState.environmentDriftCount } } `
    -RepairConfig { param($tracker) $fixtureState.configDrift = $false; $tracker.changed = $true; $tracker.restartRequired = $true } `
    -RepairEnvironment { param($tracker) $fixtureState.environmentDriftCount = 0; $tracker.changed = $true; $tracker.restartRequired = $true } `
    -NetworkProbe { throw 'network probe must not run during Repair' }
Assert-True ($successfulRepair.ok -and $successfulRepair.changed -and $successfulRepair.converged -and $successfulRepair.driftCount -eq 0 -and -not $successfulRepair.repairRequired) 'Repair 必须基于 post-read 证明最终收敛'

$fixtureState = [pscustomobject]@{ configDrift = $true; environmentDriftCount = 2 }
$remainingProcessDrift = Invoke-CodexProviderGuardCore -Repair `
    -ReadConfigState { [ordered]@{ drift = [bool]$fixtureState.configDrift } } `
    -ReadEnvironmentState { [ordered]@{ driftCount = [int]$fixtureState.environmentDriftCount } } `
    -RepairConfig { param($tracker) $fixtureState.configDrift = $false; $tracker.changed = $true; $tracker.restartRequired = $true } `
    -RepairEnvironment { param($tracker) $fixtureState.environmentDriftCount = 1; $tracker.changed = $true; $tracker.restartRequired = $true } `
    -NetworkProbe { throw 'network probe must not run during Repair' }
Assert-True (-not $remainingProcessDrift.ok -and $remainingProcessDrift.changed -and -not $remainingProcessDrift.converged -and $remainingProcessDrift.driftCount -eq 1 -and $remainingProcessDrift.repairRequired) '子进程无法消除父 Process drift 时不得假报 converged=0'

$fixtureState = [pscustomobject]@{ configDrift = $true; environmentDriftCount = 2 }
$partialRepair = Invoke-CodexProviderGuardCore -Repair `
    -ReadConfigState { [ordered]@{ drift = [bool]$fixtureState.configDrift } } `
    -ReadEnvironmentState { [ordered]@{ driftCount = [int]$fixtureState.environmentDriftCount } } `
    -RepairConfig { param($tracker) $fixtureState.configDrift = $false; $tracker.changed = $true; $tracker.restartRequired = $true } `
    -RepairEnvironment { param($tracker) $fixtureState.environmentDriftCount = 1; $tracker.changed = $true; $tracker.restartRequired = $true; throw 'fixture environment failure' } `
    -NetworkProbe { throw 'network probe must not run during Repair' }
Assert-True (-not $partialRepair.ok -and $partialRepair.changed -and $partialRepair.driftCount -eq 1 -and @($partialRepair.errors).Count -gt 0) '部分动作已提交后失败必须保留 changed 并报告 remaining drift'

'Test-CodexLocalHealthGuards: PASS'
