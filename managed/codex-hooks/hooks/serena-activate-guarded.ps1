Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. 'D:\Codex\.codex\hooks\lib\CodexHookRuntime.ps1'

$checkOnly=$false
$json=$false
$seenArguments=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach($argument in @($args)){
    $token=[string]$argument
    if(-not $seenArguments.Add($token)){throw "Serena activate 参数重复：$token"}
    switch -CaseSensitive ($token){
        '-CheckOnly' {$checkOnly=$true}
        '-Json' {$json=$true}
        default {throw "Serena activate 参数不支持：$token"}
    }
}

$started = [DateTime]::UtcNow
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$inputBuffer = [IO.MemoryStream]::new()
[Console]::OpenStandardInput().CopyTo($inputBuffer)
[byte[]]$inputBytes = $inputBuffer.ToArray()
$inputBuffer.Dispose()
if ($inputBytes.Length -eq 0) { throw 'Serena activate hook stdin 为空。' }

if($checkOnly){
    $text=[Text.UTF8Encoding]::new($false,$true).GetString($inputBytes)
    $document=[Text.Json.JsonDocument]::Parse($text)
    try{$root=$document.RootElement;$id=[Text.Json.JsonElement]::new();$hasId=$root.TryGetProperty('session_id',[ref]$id) -or $root.TryGetProperty('sessionId',[ref]$id);if(-not $hasId -or $id.ValueKind -ne [Text.Json.JsonValueKind]::String -or [string]::IsNullOrWhiteSpace($id.GetString())){throw 'Serena activate SessionStart id 缺失。'}}finally{$document.Dispose()}
    $ok=[IO.File]::Exists('D:\Codex\tools\uv\bin\serena-hooks.exe')
    if($json){[pscustomobject][ordered]@{ok=$ok;changed=$false;restartRequired=$false;errors=if($ok){[string[]]@()}else{[string[]]@('serena vendor missing')}}|ConvertTo-Json -Compress}
    if(-not $ok){throw 'Serena activate vendor 不存在。'}
    return
}

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
