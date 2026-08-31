Set-StrictMode -Version Latest

$script:CodexHookProcessDrainTimeoutMilliseconds = 250

function Receive-CodexHookBoundedProcessStream {
    param(
        [Parameter(Mandatory)][object]$Task,
        [Parameter(Mandatory)][string]$StreamName
    )
    if (-not $Task.Wait($script:CodexHookProcessDrainTimeoutMilliseconds)) {
        throw "进程 $StreamName drain 超时。"
    }
    return $Task.GetAwaiter().GetResult()
}

function Complete-CodexHookProcessWithBoundedDrain {
    param(
        [Parameter(Mandatory)][Diagnostics.Process]$Process,
        [Parameter(Mandatory)][object]$StdoutTask,
        [Parameter(Mandatory)][object]$StderrTask,
        [Parameter(Mandatory)][int]$TimeoutMilliseconds,
        [Parameter(Mandatory)][string]$ProcessName,
        [AllowNull()][object]$StdinTask = $null,
        [AllowNull()][object]$StdinStream = $null
    )
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    $stopTimedOutProcess = {
        try { $Process.Kill($true) } catch {}
        try { if ($null -ne $StdinStream) { $StdinStream.Dispose() } } catch {}
        try { [void]$Process.WaitForExit($script:CodexHookProcessDrainTimeoutMilliseconds) } catch {}
        try { if ($null -ne $StdinTask) { [void]$StdinTask.Wait($script:CodexHookProcessDrainTimeoutMilliseconds) } } catch {}
        try { [void]$StdoutTask.Wait($script:CodexHookProcessDrainTimeoutMilliseconds) } catch {}
        try { [void]$StderrTask.Wait($script:CodexHookProcessDrainTimeoutMilliseconds) } catch {}
    }
    if ($null -ne $StdinTask) {
        $remaining = [Math]::Max(0, $TimeoutMilliseconds - [int]$deadline.ElapsedMilliseconds)
        if (-not $StdinTask.Wait($remaining)) {
            & $stopTimedOutProcess
            throw "$ProcessName stdin 超时。"
        }
        try { [void]$StdinTask.GetAwaiter().GetResult() }
        catch {
            & $stopTimedOutProcess
            throw
        }
        try { if ($null -ne $StdinStream) { $StdinStream.Dispose() } } catch {
            & $stopTimedOutProcess
            throw
        }
    }
    $remaining = [Math]::Max(0, $TimeoutMilliseconds - [int]$deadline.ElapsedMilliseconds)
    if (-not $Process.WaitForExit($remaining)) {
        & $stopTimedOutProcess
        throw "$ProcessName 超时。"
    }
    try {
        [void](Receive-CodexHookBoundedProcessStream -Task $StdoutTask -StreamName "$ProcessName stdout")
        return Receive-CodexHookBoundedProcessStream -Task $StderrTask -StreamName "$ProcessName stderr"
    } catch {
        $drainError = $_
        & $stopTimedOutProcess
        throw $drainError
    }
}

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
        [scriptblock]$TestBeforeReplace,
        [scriptblock]$TestBeforeRollback,
        [scriptblock]$TestBeforeRollbackReplace
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
    $restoreTemp = $null
    $rollbackLease = $null
    $replaceBackup = $null
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
        $originalError=$_
        if ($replaced -and [IO.File]::Exists($backup)) {
            try {
                if($TestBeforeRollback){&$TestBeforeRollback $full}
                [byte[]]$backupBytes=[IO.File]::ReadAllBytes($backup)
                if(([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($backupBytes))).ToLowerInvariant() -cne $before){throw 'rollback backup SHA-256 漂移。'}
                # Keep WRITE excluded from the verified deployed target through replacement.
                $rollbackLease=[IO.File]::Open($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::Read -bor [IO.FileShare]::Delete))
                $rollbackLease.Position=0
                $rollbackLeaseSha256=([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($rollbackLease))).ToLowerInvariant()
                if($rollbackLeaseSha256 -cne $expectedAfter){throw 'rollback live SHA-256 不再匹配本 writer 发布值。'}
                if($TestBeforeRollbackReplace){&$TestBeforeRollbackReplace $full}
                # A normal user-mode delete/replace can still race after this check and before
                # File.Replace. This detects the observable window but does not claim absolute CAS.
                if((Get-CodexHookSha256 $full) -cne $expectedAfter){throw 'rollback live SHA-256 在 replace 前漂移。'}
                $restoreTemp=Join-Path $parent ('.codex-hook-restore-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
                $replaceBackup=Join-Path $parent ('.codex-hook-replace-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
                [IO.File]::WriteAllBytes($restoreTemp,$backupBytes)
                &$Validator $restoreTemp
                [IO.File]::Replace($restoreTemp,$full,$replaceBackup,$true);$restoreTemp=$null
                $rollbackLease.Dispose();$rollbackLease=$null
                if((Get-CodexHookSha256 $full) -cne $before){throw 'rollback 写后 SHA-256 不一致。'}
            }catch{
                throw "atomic write rollback-blocked; original=$($originalError.Exception.Message); rollback=$($_.Exception.Message)"
            }
        }
        throw $originalError
    } finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
        if($null -ne $restoreTemp -and [IO.File]::Exists($restoreTemp)){[IO.File]::Delete($restoreTemp)}
        if($null -ne $replaceBackup -and [IO.File]::Exists($replaceBackup)){[IO.File]::Delete($replaceBackup)}
        if($null -ne $rollbackLease){$rollbackLease.Dispose()}
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
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            try { $process.Kill($true) } catch {}
            try { [void]$process.WaitForExit($script:CodexHookProcessDrainTimeoutMilliseconds) } catch {}
            try { [void]$stdoutTask.Wait($script:CodexHookProcessDrainTimeoutMilliseconds) } catch {}
            try { [void]$stderrTask.Wait($script:CodexHookProcessDrainTimeoutMilliseconds) } catch {}
            throw "进程超时：$FilePath"
        }
        return [pscustomobject][ordered]@{
            exitCode = $process.ExitCode
            stdout = Receive-CodexHookBoundedProcessStream -Task $stdoutTask -StreamName "$FilePath stdout"
            stderr = Receive-CodexHookBoundedProcessStream -Task $stderrTask -StreamName "$FilePath stderr"
        }
    } finally { $process.Dispose() }
}

function ConvertTo-CodexHookRedactedUri {
    param([Parameter(Mandatory)][string]$Value)
    $uri = [uri]$Value
    if (-not $uri.IsAbsoluteUri -or [string]::IsNullOrWhiteSpace($uri.Host)) { throw 'URI 非法。' }
    $port = if ($uri.IsDefaultPort) { '' } else { ":$($uri.Port)" }
    return "$($uri.Scheme)://$($uri.IdnHost)$port"
}

function Assert-CodexSerenaSessionStartOutputBytes {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    if ($Bytes.Length -eq 0) { throw 'Serena activate vendor stdout 为空。' }
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $text = $utf8.GetString($Bytes)
    $document = [Text.Json.JsonDocument]::Parse($text)
    try {
        $root = $document.RootElement
        if ($root.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'Serena activate vendor JSON 根必须是 object。' }
        $rootNames = @($root.EnumerateObject() | ForEach-Object Name)
        if ($rootNames.Count -ne 1 -or $rootNames[0] -cne 'hookSpecificOutput') { throw 'Serena activate vendor JSON 顶层 schema 非法。' }
        $hookOutput = $root.GetProperty('hookSpecificOutput')
        if ($hookOutput.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'Serena activate hookSpecificOutput 必须是 object。' }
        $hookNames = @($hookOutput.EnumerateObject() | ForEach-Object Name)
        if ($hookNames.Count -ne 2 -or $hookNames -cnotcontains 'hookEventName' -or $hookNames -cnotcontains 'additionalContext') { throw 'Serena activate hookSpecificOutput schema 非法。' }
        if ($hookOutput.GetProperty('hookEventName').ValueKind -ne [Text.Json.JsonValueKind]::String -or $hookOutput.GetProperty('hookEventName').GetString() -cne 'SessionStart') { throw 'Serena activate hookEventName 非法。' }
        if ($hookOutput.GetProperty('additionalContext').ValueKind -ne [Text.Json.JsonValueKind]::String -or [string]::IsNullOrWhiteSpace($hookOutput.GetProperty('additionalContext').GetString())) { throw 'Serena activate additionalContext 非法。' }
    }
    finally { $document.Dispose() }
}

function Assert-CodexHookHealthPayload {
    param([Parameter(Mandatory)][string]$HookId, [Parameter(Mandatory)][object]$Payload)
    if ($HookId -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') { throw 'health hookId 非法。' }
    $allowed = @('hookId','runId','startedAtUtc','completedAtUtc','durationMs','ok','changed','restartRequired','errors')
    $names = @($Payload.PSObject.Properties.Name)
    if ($names.Count -ne $allowed.Count -or ((@($names | Sort-Object) -join "`0") -cne (@($allowed | Sort-Object) -join "`0"))) { throw 'health payload schema 非法。' }
    if ([string]$Payload.hookId -cne $HookId) { throw 'health hookId 不一致。' }
    if ([string]$Payload.runId -cnotmatch '^[0-9a-f]{32}$') { throw 'health runId 非法。' }
    foreach($name in @('startedAtUtc','completedAtUtc')){$parsed=[datetimeoffset]::MinValue;if(-not[datetimeoffset]::TryParse([string]$Payload.$name,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed)){throw "health $name 非法。"}}
    if($Payload.durationMs -isnot [long] -and $Payload.durationMs -isnot [int]){throw 'health durationMs 类型非法。'}
    if([long]$Payload.durationMs -lt 0){throw 'health durationMs 非法。'}
    foreach($name in @('ok','changed','restartRequired')){if($Payload.$name -isnot [bool]){throw "health $name 类型非法。"}}
    if($null -eq $Payload.errors -or $Payload.errors -is [string] -or $Payload.errors -isnot [array]){throw 'health errors 类型非法。'}
    foreach($errorText in @($Payload.errors)){if($errorText -isnot [string]){throw 'health errors 类型非法。'}}
    $normalized=[pscustomobject][ordered]@{
        hookId=[string]$Payload.hookId;runId=[string]$Payload.runId;startedAtUtc=[string]$Payload.startedAtUtc;completedAtUtc=[string]$Payload.completedAtUtc
        durationMs=[long]$Payload.durationMs;ok=[bool]$Payload.ok;changed=[bool]$Payload.changed;restartRequired=[bool]$Payload.restartRequired;errors=[string[]]@($Payload.errors)
    }
    $json = $normalized | ConvertTo-Json -Depth 8
    if ($json -match '(?i)(thread|session)[-_ ]?id|://[^/\s]*@|[?&][^\s=]+=') { throw 'health payload 含敏感标识或 URI 凭据。' }
    return $json
}

function Write-CodexHookLatestHealthCore {
    param(
        [Parameter(Mandatory)][string]$HookId,
        [Parameter(Mandatory)][object]$Payload,
        [Parameter(Mandatory)][string]$HealthRoot,
        [switch]$AllowFixtureRoot
    )
    $json=Assert-CodexHookHealthPayload -HookId $HookId -Payload $Payload
    $fixedRoot='D:\agents\run-evidence\codex-hook-health'
    $fixtureRoot='D:\agents\projects\统一环境\reports\codex-hook-health-test'
    $root=[IO.Path]::GetFullPath($HealthRoot)
    if($AllowFixtureRoot){
        $reconcilerFixture=$false
        if($root -cmatch '^D:\\agents\\projects\\统一环境\\\.scratch\\host-hook-reconciliation-tests-[0-9a-f]{32}\\[^\\]+\\\.codex\\run-evidence\\codex-hook-health\z'){
            $codexHome=[IO.Directory]::GetParent([IO.Directory]::GetParent($root).FullName).FullName
            $marker=Join-Path $codexHome '.codex-host-hook-reconciliation-fixture'
            $reconcilerFixture=(Test-Path -LiteralPath $marker -PathType Leaf)-and((Get-Content -LiteralPath $marker -Raw).Trim()-ceq'codex-host-hook-reconciliation-fixture-v1')
        }
        if($root -ine $fixtureRoot -and -not $reconcilerFixture){throw 'health fixture root 非法。'}
    }elseif($root -ine $fixedRoot){throw 'health root 必须使用固定路径。'}
    [void](Assert-CodexHookDPath -Path $root -AllowMissingLeaf)
    if (-not [IO.Directory]::Exists($root)) { [IO.Directory]::CreateDirectory($root) | Out-Null }
    [void](Assert-CodexHookDPath -Path $root)
    $path = Join-Path $root "$HookId.json"
    [void](Invoke-CodexHookMutex -Name "Local\CodexHookHealth-$HookId" -ScriptBlock {
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
    })
}

function Write-CodexHookLatestHealth {
    param([Parameter(Mandatory)][string]$HookId, [Parameter(Mandatory)][object]$Payload)
    Write-CodexHookLatestHealthCore -HookId $HookId -Payload $Payload -HealthRoot 'D:\agents\run-evidence\codex-hook-health'
}
