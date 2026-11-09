function New-UuCommandEnvelope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][string]$MarkerRoot
    )
    if ([string]::IsNullOrWhiteSpace($Command)) { throw 'Command must not be empty' }
    if ($MarkerRoot -match '[&|^<>"]') { throw 'Marker root contains unsupported CMD characters' }
    $bytes = [Text.Encoding]::UTF8.GetBytes($Command)
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    $directory = Join-Path $MarkerRoot $RunId
    $markerPath = Join-Path $directory "command-$Index.json"
    $temporary = "$markerPath.tmp"
    $marker = [ordered]@{ runId = $RunId; index = $Index; commandSha256 = $hash } | ConvertTo-Json -Compress
    # 命令以退出码 0 结束才写 marker；失败时 reader 等不到 marker，序列在这一条闭锁。
    $wrapped = "mkdir `"$directory`" 2>nul & ($Command) && (> `"$temporary`" echo $marker) && move /Y `"$temporary`" `"$markerPath`""
    [pscustomobject]@{
        markerPath = $markerPath
        commandSha256 = $hash
        wrappedCommand = $wrapped
    }
}

function Invoke-UuCommandSequence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Command,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$MarkerRoot,
        [Parameter(Mandatory)][scriptblock]$SendCommand,
        [Parameter(Mandatory)][scriptblock]$MarkerReader,
        [ValidateRange(1, 120)][int]$ProofTimeoutSeconds = 20,
        [ValidateRange(10, 5000)][int]$PollMilliseconds = 250
    )
    $results = [System.Collections.Generic.List[object]]::new()
    $completed = 0
    $status = 'executed'
    for ($index = 0; $index -lt $Command.Count; $index++) {
        $envelope = New-UuCommandEnvelope -Command $Command[$index] -RunId $RunId -Index $index -MarkerRoot $MarkerRoot
        try {
            & $SendCommand $envelope.wrappedCommand $envelope.markerPath
        } catch {
            $results.Add([pscustomobject]@{ index = $index; commandSha256 = $envelope.commandSha256; status = 'transport-failed'; markerPath = $envelope.markerPath })
            $status = 'blocked'
            break
        }
        $deadline = [DateTime]::UtcNow.AddSeconds($ProofTimeoutSeconds)
        $proved = $false
        while ([DateTime]::UtcNow -lt $deadline) {
            try {
                if (& $MarkerReader $envelope.markerPath $envelope.commandSha256 $RunId $index) {
                    $proved = $true
                    break
                }
            } catch { }
            Start-Sleep -Milliseconds $PollMilliseconds
        }
        if (-not $proved) {
            $results.Add([pscustomobject]@{ index = $index; commandSha256 = $envelope.commandSha256; status = 'marker-timeout'; markerPath = $envelope.markerPath })
            $status = 'blocked'
            break
        }
        $results.Add([pscustomobject]@{ index = $index; commandSha256 = $envelope.commandSha256; status = 'executed'; markerPath = $envelope.markerPath })
        $completed++
    }
    [pscustomobject]@{
        status = $status
        completedCount = $completed
        results = @($results)
    }
}

function Stop-ProcessByPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProcessName,
        [Parameter(Mandatory)][string]$ExpectedPath,
        [scriptblock]$ProcessProvider = { Get-CimInstance Win32_Process -Filter "Name = '$ProcessName'" },
        [scriptblock]$ProcessStopper = { param($Id) Stop-Process -Id $Id -Force -ErrorAction Stop },
        [scriptblock]$ProcessLookup = { param($Id) Get-Process -Id $Id -ErrorAction SilentlyContinue }
    )
    $expected = [IO.Path]::GetFullPath($ExpectedPath)
    $stopped = [System.Collections.Generic.List[int]]::new()
    $items = @(& $ProcessProvider)
    # 全部核对通过才开始停止：任何一个路径不符都不动已核对过的进程。
    foreach ($item in $items) {
        if (-not $item.ExecutablePath) { throw "Unable to verify process path for $ProcessName" }
        $actual = [IO.Path]::GetFullPath($item.ExecutablePath)
        if ($actual -ine $expected) { throw "Unexpected process path for $ProcessName" }
    }
    foreach ($item in $items) {
        try {
            & $ProcessStopper $item.ProcessId
        } catch {
            if (& $ProcessLookup $item.ProcessId) { throw }
        }
        $stopped.Add([int]$item.ProcessId)
    }
    @($stopped)
}

function Test-StudyLink {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$PingHandler,
        [Parameter(Mandatory)][scriptblock]$SshHandler
    )
    $ping = & $PingHandler
    if (-not $ping.success) {
        return [pscustomobject]@{ status = 'offline'; connectionType = 'unreachable'; sshSuccess = $null }
    }
    $ssh = & $SshHandler
    [pscustomobject]@{
        status = if ($ssh.success) { 'online' } else { 'ssh-failed' }
        connectionType = [string]$ping.connectionType
        sshSuccess = [bool]$ssh.success
    }
}

Export-ModuleMember -Function @('New-UuCommandEnvelope', 'Invoke-UuCommandSequence', 'Stop-ProcessByPath', 'Test-StudyLink')
