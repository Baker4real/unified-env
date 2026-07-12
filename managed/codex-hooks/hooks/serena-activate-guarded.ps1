Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. 'D:\Codex\.codex\hooks\lib\CodexHookRuntime.ps1'

$started = [DateTime]::UtcNow
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$inputBuffer = [IO.MemoryStream]::new()
[Console]::OpenStandardInput().CopyTo($inputBuffer)
[byte[]]$inputBytes = $inputBuffer.ToArray()
$inputBuffer.Dispose()
if ($inputBytes.Length -eq 0) { throw 'Serena activate hook stdin 为空。' }

$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = 'D:\Codex\tools\uv\bin\serena-hooks.exe'
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardInput = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
[void]$startInfo.ArgumentList.Add('activate')
[void]$startInfo.ArgumentList.Add('--client=codex')
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
    Assert-CodexSerenaSessionStartOutputBytes -Bytes $vendorBytes

    $stopwatch.Stop()
    $health = [pscustomobject][ordered]@{
        hookId = 'serena-activate'; runId = [guid]::NewGuid().ToString('N')
        startedAtUtc = $started.ToString('o'); completedAtUtc = [DateTime]::UtcNow.ToString('o')
        durationMs = [long]$stopwatch.ElapsedMilliseconds; ok = $true; changed = $false
        restartRequired = $false; errors = [string[]]@()
    }
    Write-CodexHookLatestHealth -HookId 'serena-activate' -Payload $health
    $output = [Console]::OpenStandardOutput()
    $output.Write($vendorBytes, 0, $vendorBytes.Length)
    $output.Flush()
}
catch {
    $stopwatch.Stop()
    $failedHealth = [pscustomobject][ordered]@{
        hookId = 'serena-activate'; runId = [guid]::NewGuid().ToString('N')
        startedAtUtc = $started.ToString('o'); completedAtUtc = [DateTime]::UtcNow.ToString('o')
        durationMs = [long]$stopwatch.ElapsedMilliseconds; ok = $false; changed = $false
        restartRequired = $false; errors = [string[]]@('serena activate protocol validation failed')
    }
    Write-CodexHookLatestHealth -HookId 'serena-activate' -Payload $failedHealth
    throw
}
finally {
    $stdoutBuffer.Dispose()
    $process.Dispose()
    $stopwatch.Stop()
}
