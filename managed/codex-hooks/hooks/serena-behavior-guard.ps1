[CmdletBinding()]
param(
    [ValidateSet('Reminder', 'Cleanup', 'Activation', 'ReminderAcceptance', 'CleanupAcceptance', 'ActivationAcceptance')]
    [string]$Mode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-CodexSerenaSessionStartInput {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$InputText)

    if ([string]::IsNullOrWhiteSpace($InputText)) { throw 'Serena SessionStart payload 为空。' }
    $document = [Text.Json.JsonDocument]::Parse($InputText)
    try {
        $root = $document.RootElement
        if ($root.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'Serena SessionStart payload 根非法。' }
        $ids = @($root.EnumerateObject() | Where-Object { $_.Name -ceq 'session_id' -or $_.Name -ceq 'sessionId' })
        if ($ids.Count -ne 1 -or $ids[0].Value.ValueKind -ne [Text.Json.JsonValueKind]::String -or [string]::IsNullOrWhiteSpace($ids[0].Value.GetString())) {
            throw 'Serena SessionStart id 非法。'
        }
    }
    finally { $document.Dispose() }
}

function Assert-CodexSerenaBehaviorOutput {
    param(
        [Parameter(Mandatory)][ValidateSet('Reminder', 'Cleanup', 'Activation')][string]$Behavior,
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes
    )

    if ($Behavior -ceq 'Activation') {
        Assert-CodexSerenaSessionStartOutputBytes -Bytes $Bytes
        return
    }
    if ($Behavior -ceq 'Cleanup') {
        if ($Bytes.Length -ne 0) { throw 'Serena cleanup stdout 协议非法。' }
        return
    }
    if ($Bytes.Length -eq 0) { return }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
    $document = [Text.Json.JsonDocument]::Parse($text)
    try {
        $root = $document.RootElement
        if ($root.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'Serena reminder JSON 根非法。' }
        $rootNames = @($root.EnumerateObject() | ForEach-Object Name)
        if ($rootNames.Count -ne 1 -or $rootNames[0] -cne 'hookSpecificOutput') { throw 'Serena reminder 顶层 schema 非法。' }
        $output = $root.GetProperty('hookSpecificOutput')
        if ($output.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'Serena reminder hookSpecificOutput 非法。' }
        $names = @($output.EnumerateObject() | ForEach-Object Name)
        $expected = @('hookEventName', 'permissionDecision', 'permissionDecisionReason')
        if ($names.Count -ne $expected.Count -or (@($names | Sort-Object) -join "`0") -cne (@($expected | Sort-Object) -join "`0")) { throw 'Serena reminder hookSpecificOutput schema 非法。' }
        if ($output.GetProperty('hookEventName').GetString() -cne 'PreToolUse') { throw 'Serena reminder hookEventName 非法。' }
        if ($output.GetProperty('permissionDecision').GetString() -cne 'deny') { throw 'Serena reminder permissionDecision 非法。' }
        if ([string]::IsNullOrWhiteSpace($output.GetProperty('permissionDecisionReason').GetString())) { throw 'Serena reminder reason 非法。' }
    }
    finally { $document.Dispose() }
}

function Invoke-CodexSerenaBehaviorGuardCore {
    param(
        [Parameter(Mandatory)][ValidateSet('Reminder', 'Cleanup', 'Activation')][string]$Behavior,
        [Parameter(Mandatory)][AllowEmptyString()][string]$InputText,
        [Parameter(Mandatory)][string]$VendorPath,
        [Parameter(Mandatory)][string]$SerenaHome,
        [Parameter(Mandatory)][string]$RuntimePath,
        [Parameter(Mandatory)][string]$HealthRoot,
        [switch]$AllowFixture
    )

    $productionVendor = 'D:\Codex\tools\uv\bin\serena-hooks.exe'
    $productionHome = 'D:\Codex\.serena'
    $productionRuntime = 'D:\Codex\.codex\hooks\lib\CodexHookRuntime.ps1'
    $productionHealth = 'D:\Codex\.codex\run-evidence\codex-hook-health'
    $fixtureHome = 'D:\Codex\projects\统一环境\reports\codex-hook-serena-behavior-fixture\.serena'
    $fixtureRuntime = 'D:\Codex\projects\统一环境\managed\codex-hooks\hooks\lib\CodexHookRuntime.ps1'
    $fixtureHealth = 'D:\Codex\projects\统一环境\reports\codex-hook-health-test'
    if ($VendorPath -ine $productionVendor) { throw 'Serena behavior vendor capability 非法。' }
    if ($AllowFixture) {
        if ($SerenaHome -ine $fixtureHome -or $RuntimePath -ine $fixtureRuntime -or $HealthRoot -ine $fixtureHealth) { throw 'Serena behavior fixture capability 非法。' }
    }
    elseif ($SerenaHome -ine $productionHome -or $RuntimePath -ine $productionRuntime -or $HealthRoot -ine $productionHealth) {
        throw 'Serena behavior production capability 非法。'
    }

    . $RuntimePath
    $hookId = if ($Behavior -ceq 'Reminder') { 'serena-reminder' } elseif ($Behavior -ceq 'Cleanup') { 'serena-cleanup' } else { 'serena-activate' }
    $vendorCommand = if ($Behavior -ceq 'Reminder') { 'remind' } else { 'cleanup' }
    $started = [DateTime]::UtcNow
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $productionVendor
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment['SERENA_HOME'] = $SerenaHome
    [void]$startInfo.ArgumentList.Add($vendorCommand)
    [void]$startInfo.ArgumentList.Add('--client=codex')
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $buffer = [IO.MemoryStream]::new()
    try {
        if ($Behavior -ceq 'Activation') {
            Assert-CodexSerenaSessionStartInput -InputText $InputText
            $context = 'Use the absolute workspace root from environment_context to call mcp__serena__activate_project, then call mcp__serena__get_current_config to verify the active project. Do not infer the project from cwd.'
            $activationJson = [pscustomobject][ordered]@{ hookSpecificOutput = [pscustomobject][ordered]@{ hookEventName = 'SessionStart'; additionalContext = $context } } | ConvertTo-Json -Compress -Depth 4
            [byte[]]$bytes = [Text.UTF8Encoding]::new($false).GetBytes($activationJson + "`r`n")
        }
        else {
            if (-not $process.Start()) { throw 'Serena behavior vendor 启动失败。' }
            $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($buffer)
            $stderrTask = $process.StandardError.ReadToEndAsync()
            $process.StandardInput.Write($InputText)
            $process.StandardInput.Close()
            $stderr = Complete-CodexHookProcessWithBoundedDrain -Process $process -StdoutTask $stdoutTask -StderrTask $stderrTask -TimeoutMilliseconds 5000 -ProcessName 'Serena behavior vendor'
            [byte[]]$bytes = $buffer.ToArray()
            if ($process.ExitCode -ne 0 -or -not [string]::IsNullOrWhiteSpace($stderr)) { throw 'Serena behavior vendor 失败。' }
        }
        Assert-CodexSerenaBehaviorOutput -Behavior $Behavior -Bytes $bytes
        if ($Behavior -ceq 'Reminder' -and $bytes.Length -eq 0) {
            $watch.Stop()
            return [pscustomobject][ordered]@{ ok = $true; exitCode = 0; stdout = $bytes; error = $null }
        }
        $watch.Stop()
        $health = [pscustomobject][ordered]@{
            hookId = $hookId; runId = [guid]::NewGuid().ToString('N'); startedAtUtc = $started.ToString('o')
            completedAtUtc = [DateTime]::UtcNow.ToString('o'); durationMs = [long]$watch.ElapsedMilliseconds
            ok = $true; changed = $false; restartRequired = $false; errors = [string[]]@()
        }
        $null = Write-CodexHookLatestHealthCore -HookId $hookId -Payload $health -HealthRoot $HealthRoot -AllowFixtureRoot:$AllowFixture
        return [pscustomobject][ordered]@{ ok = $true; exitCode = 0; stdout = $bytes; error = $null }
    }
    catch {
        $watch.Stop()
        $health = [pscustomobject][ordered]@{
            hookId = $hookId; runId = [guid]::NewGuid().ToString('N'); startedAtUtc = $started.ToString('o')
            completedAtUtc = [DateTime]::UtcNow.ToString('o'); durationMs = [long]$watch.ElapsedMilliseconds
            ok = $false; changed = $false; restartRequired = $false; errors = [string[]]@('serena behavior protocol validation failed')
        }
        try { $null = Write-CodexHookLatestHealthCore -HookId $hookId -Payload $health -HealthRoot $HealthRoot -AllowFixtureRoot:$AllowFixture } catch {}
        return [pscustomobject][ordered]@{ ok = $false; exitCode = 1; stdout = [byte[]]@(); error = 'serena behavior hook failed' }
    }
    finally {
        $watch.Stop()
        $buffer.Dispose()
        $process.Dispose()
    }
}

function Invoke-CodexSerenaBehaviorAcceptanceCore {
    param(
        [Parameter(Mandatory)][ValidateSet('Reminder', 'Cleanup', 'Activation')][string]$Behavior,
        [Parameter(Mandatory)][string]$VendorPath,
        [Parameter(Mandatory)][string]$SerenaHome,
        [Parameter(Mandatory)][string]$RuntimePath,
        [Parameter(Mandatory)][string]$HealthRoot,
        [switch]$AllowFixture
    )

    $sessionId = [guid]::NewGuid().ToString()
    if ($Behavior -ceq 'Activation') {
        $activationPayload = [pscustomobject][ordered]@{ session_id = $sessionId } | ConvertTo-Json -Compress
        $activation = Invoke-CodexSerenaBehaviorGuardCore -Behavior Activation -InputText $activationPayload -VendorPath $VendorPath -SerenaHome $SerenaHome -RuntimePath $RuntimePath -HealthRoot $HealthRoot -AllowFixture:$AllowFixture
        if (-not $activation.ok -or $activation.exitCode -ne 0 -or $activation.stdout.Length -eq 0) { throw 'Serena activation acceptance 失败。' }
        return [pscustomobject][ordered]@{ ok = $true; exitCode = 0; sessionId = $null }
    }

    $sessionPath = Join-Path $SerenaHome "hook_data\$sessionId"
    $payload = [pscustomobject][ordered]@{
        session_id = $sessionId
        tool_name = 'Bash'
        tool_input = [pscustomobject][ordered]@{ command = 'rg -n hook file.ps1' }
    } | ConvertTo-Json -Compress -Depth 4
    try {
        if ($Behavior -ceq 'Reminder') {
            foreach ($attempt in 1..3) {
                $result = Invoke-CodexSerenaBehaviorGuardCore -Behavior Reminder -InputText $payload -VendorPath $VendorPath -SerenaHome $SerenaHome -RuntimePath $RuntimePath -HealthRoot $HealthRoot -AllowFixture:$AllowFixture
                if (-not $result.ok -or $result.exitCode -ne 0) { throw 'Serena reminder acceptance 失败。' }
                if ($attempt -lt 3 -and $result.stdout.Length -ne 0) { throw 'Serena reminder acceptance 过早提醒。' }
                if ($attempt -eq 3 -and $result.stdout.Length -eq 0) { throw 'Serena reminder acceptance 未达到阈值。' }
            }
        }
        else {
            $seed = Invoke-CodexSerenaBehaviorGuardCore -Behavior Reminder -InputText $payload -VendorPath $VendorPath -SerenaHome $SerenaHome -RuntimePath $RuntimePath -HealthRoot $HealthRoot -AllowFixture:$AllowFixture
            if (-not $seed.ok -or $seed.stdout.Length -ne 0 -or -not (Test-Path -LiteralPath $sessionPath -PathType Container)) { throw 'Serena cleanup acceptance seed 失败。' }
        }
    }
    finally {
        $cleanupPayload = [pscustomobject][ordered]@{ session_id = $sessionId } | ConvertTo-Json -Compress
        $cleanup = Invoke-CodexSerenaBehaviorGuardCore -Behavior Cleanup -InputText $cleanupPayload -VendorPath $VendorPath -SerenaHome $SerenaHome -RuntimePath $RuntimePath -HealthRoot $HealthRoot -AllowFixture:$AllowFixture
        if (-not $cleanup.ok -or $cleanup.exitCode -ne 0 -or $cleanup.stdout.Length -ne 0 -or (Test-Path -LiteralPath $sessionPath)) { throw 'Serena behavior acceptance cleanup 失败。' }
    }
    return [pscustomobject][ordered]@{ ok = $true; exitCode = 0; sessionId = $sessionId }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($Mode)) {
        [Console]::Error.WriteLine('serena behavior hook failed')
        exit 1
    }
    if ($Mode.EndsWith('Acceptance', [StringComparison]::Ordinal)) {
        try {
            $behavior = $Mode.Substring(0, $Mode.Length - 'Acceptance'.Length)
            $null = Invoke-CodexSerenaBehaviorAcceptanceCore -Behavior $behavior `
                -VendorPath 'D:\Codex\tools\uv\bin\serena-hooks.exe' `
                -SerenaHome 'D:\Codex\.serena' `
                -RuntimePath 'D:\Codex\.codex\hooks\lib\CodexHookRuntime.ps1' `
                -HealthRoot 'D:\Codex\.codex\run-evidence\codex-hook-health'
            exit 0
        }
        catch {
            [Console]::Error.WriteLine('serena behavior acceptance failed')
            exit 1
        }
    }
    $inputText = [Console]::In.ReadToEnd()
    $result = Invoke-CodexSerenaBehaviorGuardCore -Behavior $Mode -InputText $inputText `
        -VendorPath 'D:\Codex\tools\uv\bin\serena-hooks.exe' `
        -SerenaHome 'D:\Codex\.serena' `
        -RuntimePath 'D:\Codex\.codex\hooks\lib\CodexHookRuntime.ps1' `
        -HealthRoot 'D:\Codex\.codex\run-evidence\codex-hook-health'
    if (-not $result.ok) {
        [Console]::Error.WriteLine($result.error)
        exit $result.exitCode
    }
    if ($result.stdout.Length -gt 0) {
        $standardOutput = [Console]::OpenStandardOutput()
        $standardOutput.Write($result.stdout, 0, $result.stdout.Length)
        $standardOutput.Flush()
    }
    exit 0
}
