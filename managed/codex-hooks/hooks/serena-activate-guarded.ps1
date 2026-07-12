param(
    [string]$VendorPath = 'D:\Codex\tools\uv\bin\serena-hooks.exe',
    [string]$FixtureVendorScriptPath = '',
    [string]$RuntimePath = 'D:\Codex\.codex\hooks\lib\CodexHookRuntime.ps1',
    [string]$HealthRoot = 'D:\Codex\.codex\run-evidence\codex-hook-health',
    [switch]$AllowFixture
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$fixtureVendor = 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe'
$fixtureVendorScript = 'D:\Codex\projects\统一环境\reports\codex-hook-serena-fixture\serena-hooks-fixture.ps1'
$fixtureRuntime = 'D:\Codex\projects\统一环境\managed\codex-hooks\hooks\lib\CodexHookRuntime.ps1'
$fixtureHealth = 'D:\Codex\projects\统一环境\reports\codex-hook-health-test'
if ($AllowFixture) {
    if ($VendorPath -ine $fixtureVendor -or $FixtureVendorScriptPath -ine $fixtureVendorScript -or $RuntimePath -ine $fixtureRuntime -or $HealthRoot -ine $fixtureHealth) {
        throw 'Serena activate fixture capability 路径非法。'
    }
}
elseif (
    $VendorPath -ine 'D:\Codex\tools\uv\bin\serena-hooks.exe' -or
    -not [string]::IsNullOrEmpty($FixtureVendorScriptPath) -or
    $RuntimePath -ine 'D:\Codex\.codex\hooks\lib\CodexHookRuntime.ps1' -or
    $HealthRoot -ine 'D:\Codex\.codex\run-evidence\codex-hook-health'
) {
    throw 'Serena activate production capability 路径非法。'
}
. $RuntimePath

$started = [DateTime]::UtcNow
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$inputBuffer = [IO.MemoryStream]::new()
[Console]::OpenStandardInput().CopyTo($inputBuffer)
[byte[]]$inputBytes = $inputBuffer.ToArray()
$inputBuffer.Dispose()
if ($inputBytes.Length -eq 0) { throw 'Serena activate hook stdin 为空。' }

$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $VendorPath
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardInput = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
[void]$startInfo.ArgumentList.Add('activate')
[void]$startInfo.ArgumentList.Add('--client=codex')
if ($AllowFixture) {
    $startInfo.ArgumentList.Clear()
    [void]$startInfo.ArgumentList.Add('-NoProfile')
    [void]$startInfo.ArgumentList.Add('-File')
    [void]$startInfo.ArgumentList.Add($FixtureVendorScriptPath)
    [void]$startInfo.ArgumentList.Add('activate')
    [void]$startInfo.ArgumentList.Add('--client=codex')
}
$process = [Diagnostics.Process]::new()
$process.StartInfo = $startInfo
$stdoutBuffer = [IO.MemoryStream]::new()
try {
    if (-not $process.Start()) { throw 'Serena activate vendor 启动失败。' }
    $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdoutBuffer)
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.StandardInput.BaseStream.Write($inputBytes, 0, $inputBytes.Length)
    $process.StandardInput.Close()
    if (-not $process.WaitForExit(5000)) {
        try { $process.Kill($true) } catch {}
        throw 'Serena activate vendor 超时。'
    }
    [void]$stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    [byte[]]$vendorBytes = $stdoutBuffer.ToArray()
    if ($process.ExitCode -ne 0) { throw "Serena activate vendor 退出码非零：$($process.ExitCode)。" }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) { throw 'Serena activate vendor stderr 非空。' }
    if ($vendorBytes.Length -eq 0) { throw 'Serena activate vendor stdout 为空。' }

    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $vendorText = $utf8.GetString($vendorBytes)
    $document = [Text.Json.JsonDocument]::Parse($vendorText)
    try {
        $root = $document.RootElement
        if ($root.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'Serena activate vendor JSON 根必须是 object。' }
        $rootNames = @($root.EnumerateObject() | ForEach-Object Name)
        if ($rootNames.Count -ne 1 -or $rootNames[0] -cne 'hookSpecificOutput') { throw 'Serena activate vendor JSON 顶层 schema 非法。' }
        $hookOutput = $root.GetProperty('hookSpecificOutput')
        if ($hookOutput.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'Serena activate hookSpecificOutput 必须是 object。' }
        $hookNames = @($hookOutput.EnumerateObject() | ForEach-Object Name)
        if (($hookNames -join "`0") -cne ('hookEventName','additionalContext' -join "`0")) { throw 'Serena activate hookSpecificOutput schema 非法。' }
        if ($hookOutput.GetProperty('hookEventName').ValueKind -ne [Text.Json.JsonValueKind]::String -or $hookOutput.GetProperty('hookEventName').GetString() -cne 'SessionStart') { throw 'Serena activate hookEventName 非法。' }
        if ($hookOutput.GetProperty('additionalContext').ValueKind -ne [Text.Json.JsonValueKind]::String -or [string]::IsNullOrWhiteSpace($hookOutput.GetProperty('additionalContext').GetString())) { throw 'Serena activate additionalContext 非法。' }
    }
    finally { $document.Dispose() }

    $stopwatch.Stop()
    $health = [pscustomobject][ordered]@{
        hookId = 'serena-activate'
        runId = [guid]::NewGuid().ToString('N')
        startedAtUtc = $started.ToString('o')
        completedAtUtc = [DateTime]::UtcNow.ToString('o')
        durationMs = [long]$stopwatch.ElapsedMilliseconds
        ok = $true
        changed = $false
        restartRequired = $false
        errors = [string[]]@()
    }
    if ($AllowFixture) { Write-CodexHookLatestHealthCore -HookId 'serena-activate' -Payload $health -HealthRoot $HealthRoot -AllowFixtureRoot }
    else { Write-CodexHookLatestHealth -HookId 'serena-activate' -Payload $health }
    $output = [Console]::OpenStandardOutput()
    $output.Write($vendorBytes, 0, $vendorBytes.Length)
    $output.Flush()
}
catch {
    $stopwatch.Stop()
    $failedHealth = [pscustomobject][ordered]@{
        hookId = 'serena-activate'
        runId = [guid]::NewGuid().ToString('N')
        startedAtUtc = $started.ToString('o')
        completedAtUtc = [DateTime]::UtcNow.ToString('o')
        durationMs = [long]$stopwatch.ElapsedMilliseconds
        ok = $false
        changed = $false
        restartRequired = $false
        errors = [string[]]@('serena activate protocol validation failed')
    }
    if ($AllowFixture) { Write-CodexHookLatestHealthCore -HookId 'serena-activate' -Payload $failedHealth -HealthRoot $HealthRoot -AllowFixtureRoot }
    else { Write-CodexHookLatestHealth -HookId 'serena-activate' -Payload $failedHealth }
    throw
}
finally {
    $stdoutBuffer.Dispose()
    $process.Dispose()
    $stopwatch.Stop()
}
