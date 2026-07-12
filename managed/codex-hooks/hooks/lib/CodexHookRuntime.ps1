Set-StrictMode -Version Latest

function Get-CodexHookSha256 {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.File]::Exists($Path)) { throw "文件不存在：$Path" }
    return ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($Path)))).ToLowerInvariant()
}

function Assert-CodexHookDPath {
    param([Parameter(Mandatory)][string]$Path, [switch]$AllowMissingLeaf)
    if ($Path -match '(^|[\\/])\.\.([\\/]|$)' -or ($Path.Length -gt 2 -and $Path.Substring(2).Contains(':'))) { throw "路径语法不安全：$Path" }
    $full = [IO.Path]::GetFullPath($Path)
    if (-not [IO.Path]::IsPathFullyQualified($full) -or -not $full.StartsWith('D:\', [StringComparison]::OrdinalIgnoreCase)) { throw "仅允许 D 盘绝对路径：$Path" }
    $root = [IO.Path]::GetPathRoot($full)
    $relative = $full.Substring($root.Length)
    $current = $root.TrimEnd('\')
    $parts = @($relative -split '[\\/]' | Where-Object { $_ })
    for ($i = 0; $i -lt $parts.Count; $i++) {
        $current = Join-Path $current $parts[$i]
        if (-not (Test-Path -LiteralPath $current)) {
            if ($AllowMissingLeaf -and $i -eq $parts.Count - 1) { break }
            if ($i -lt $parts.Count - 1) { throw "路径祖先不存在：$current" }
            break
        }
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "路径包含 reparse point：$current" }
        if ($i -lt $parts.Count - 1 -and -not $item.PSIsContainer) { throw "路径祖先不是目录：$current" }
    }
    return $full
}

function Invoke-CodexHookMutex {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$ScriptBlock)
    $mutex = [Threading.Mutex]::new($false, $Name)
    $held = $false
    try {
        try { $held = $mutex.WaitOne(1500) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw "等待互斥锁超时：$Name" }
        return & $ScriptBlock
    } finally {
        if ($held) { [void]$mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Write-CodexHookAtomicText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][scriptblock]$Validator,
        [Parameter(Mandatory)][string]$BackupRoot,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExpectedBeforeSha256,
        [scriptblock]$TestBeforeFinalHash,
        [scriptblock]$TestBeforeReplace
    )
    $full = Assert-CodexHookDPath -Path $Path
    $backupFull = Assert-CodexHookDPath -Path $BackupRoot -AllowMissingLeaf
    if (-not [IO.File]::Exists($full)) { throw "目标文件不存在：$full" }
    $parent = Split-Path -Parent $full
    [void](Assert-CodexHookDPath -Path $parent)
    if (-not [IO.Directory]::Exists($backupFull)) { [IO.Directory]::CreateDirectory($backupFull) | Out-Null }
    [void](Assert-CodexHookDPath -Path $backupFull)
    $before = Get-CodexHookSha256 -Path $full
    if ($before -cne $ExpectedBeforeSha256) { throw '写前 SHA-256 漂移。' }
    $temp = Join-Path $parent ('.codex-hook-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    $backup = Join-Path $backupFull ('{0}-{1}.bak' -f [IO.Path]::GetFileName($full), [guid]::NewGuid().ToString('N'))
    $encoding = [Text.UTF8Encoding]::new($false)
    $replaced = $false
    try {
        [IO.File]::WriteAllText($temp, $Text, $encoding)
        & $Validator $temp
        $expectedAfter = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($encoding.GetBytes($Text)))).ToLowerInvariant()
        if ($expectedAfter -ceq $before) {
            & $Validator $full
            return [pscustomobject][ordered]@{ changed = $false; beforeSha256 = $before; afterSha256 = $before; backupPath = $null }
        }
        if ($TestBeforeFinalHash) { & $TestBeforeFinalHash $full }
        [IO.File]::Copy($full, $backup, $false)
        if ((Get-CodexHookSha256 -Path $backup) -cne $before) { throw '备份 SHA-256 与旧文件不一致。' }
        if ((Get-CodexHookSha256 -Path $full) -cne $ExpectedBeforeSha256) { throw '最终写前 SHA-256 漂移。' }
        if ($TestBeforeReplace) { & $TestBeforeReplace $full }
        [IO.File]::Move($temp, $full, $true)
        $replaced = $true
        & $Validator $full
        if ((Get-CodexHookSha256 -Path $full) -cne $expectedAfter) { throw '写后 SHA-256 不一致。' }
        return [pscustomobject][ordered]@{ changed = ($before -cne $expectedAfter); beforeSha256 = $before; afterSha256 = $expectedAfter; backupPath = $backup }
    } catch {
        if ($replaced -and [IO.File]::Exists($backup)) { [IO.File]::Copy($backup, $full, $true) }
        throw
    } finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
    }
}

function Invoke-CodexHookProcess {
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @(), [int]$TimeoutMilliseconds = 5000)
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath; $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    foreach ($arg in $ArgumentList) { [void]$psi.ArgumentList.Add($arg) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $psi
    try {
        if (-not $process.Start()) { throw "进程启动失败：$FilePath" }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync(); $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) { try { $process.Kill($true) } catch {}; throw "进程超时：$FilePath" }
        return [pscustomobject][ordered]@{ exitCode = $process.ExitCode; stdout = $stdoutTask.GetAwaiter().GetResult(); stderr = $stderrTask.GetAwaiter().GetResult() }
    } finally { $process.Dispose() }
}

function ConvertTo-CodexHookRedactedUri {
    param([Parameter(Mandatory)][string]$Value)
    $uri = [uri]$Value
    if (-not $uri.IsAbsoluteUri -or [string]::IsNullOrWhiteSpace($uri.Host)) { throw 'URI 非法。' }
    $port = if ($uri.IsDefaultPort) { '' } else { ":$($uri.Port)" }
    return "$($uri.Scheme)://$($uri.IdnHost)$port"
}

function Write-CodexHookLatestHealth {
    param([Parameter(Mandatory)][string]$HookId, [Parameter(Mandatory)][object]$Payload)
    if ($HookId -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') { throw 'health hookId 非法。' }
    $allowed = @('hookId','runId','startedAtUtc','completedAtUtc','durationMs','ok','changed','restartRequired','errors')
    $names = @($Payload.PSObject.Properties.Name)
    if (($names -join "`0") -cne ($allowed -join "`0")) { throw 'health payload schema 非法。' }
    if ([string]$Payload.hookId -cne $HookId) { throw 'health hookId 不一致。' }
    $json = $Payload | ConvertTo-Json -Depth 8
    if ($json -match '(?i)(thread|session)[-_ ]?id|://[^/\s]*@|[?&][^\s=]+=') { throw 'health payload 含敏感标识或 URI 凭据。' }
    $root = 'D:\Codex\.codex\run-evidence\codex-hook-health'
    if (-not [IO.Directory]::Exists($root)) { [IO.Directory]::CreateDirectory($root) | Out-Null }
    $path = Join-Path $root "$HookId.json"
    return Invoke-CodexHookMutex -Name "Local\CodexHookHealth-$HookId" -ScriptBlock {
        if ([IO.File]::Exists($path)) {
            $before = Get-CodexHookSha256 $path
            return Write-CodexHookAtomicText -Path $path -Text $json -Validator { param($p) $null = Get-Content -Raw -LiteralPath $p | ConvertFrom-Json } -BackupRoot (Join-Path $root '.backups') -ExpectedBeforeSha256 $before
        }
        [void](Assert-CodexHookDPath -Path $path -AllowMissingLeaf)
        $temp = Join-Path $root (".$HookId-$([guid]::NewGuid().ToString('N')).tmp")
        try {
            [IO.File]::WriteAllText($temp, $json, [Text.UTF8Encoding]::new($false))
            $null = Get-Content -Raw -LiteralPath $temp | ConvertFrom-Json
            [IO.File]::Move($temp, $path, $false)
            if (-not [IO.File]::Exists($path)) { throw 'health 首次原子发布后文件缺失。' }
            return [pscustomobject][ordered]@{ changed = $true; beforeSha256 = $null; afterSha256 = Get-CodexHookSha256 $path; backupPath = $null }
        } finally {
            if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
        }
    }
}
