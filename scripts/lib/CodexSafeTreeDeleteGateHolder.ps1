Set-StrictMode -Version Latest

# #77 gate holder 面包屑：safe-tree-delete deployment mutex 的持锁者在 state root（与
# maintenance.json 同目录）留下 gate-holder.json，等锁超时方据此报告"谁在持锁"。
# 写、读与 stale 判定的唯一实现，由三方共用：gate shim（部署工具安装时把本文件内联进
# shim，已安装 shim 自包含）、Deploy-CodexSafeTreeDelete.ps1（mode=deploy）与后续 policy
# 维护工具。本文件只定义函数，加载时不做任何 I/O。
#
# 契约：
# - 只有持锁者写与删：取锁后原子写（同目录临时文件 + 覆盖式 rename），释放锁前删除；
#   前持有者被杀（mutex abandoned）留下的残留由下一个获得者直接覆盖。
# - 内容只有 pid、processStartUtc、mode、acquiredAtUtc，ASCII-only；mode 只来自 -Mode
#   参数，否则为 unknown；不记录目标路径或其它参数。
# - 写失败是有意降级：吞掉异常并返回 $false，绝不阻塞调用。
# - 读永不抛出：读不到或格式不符返回 {state:'unknown'}，否则返回
#   {pid, mode, acquiredAtUtc, heldSeconds, stale}。stale=$true 表示无法确认面包屑描述
#   一个存活进程：PID 不存在、已退出、启动时间不符或无法查询。

function Get-CodexSafeTreeDeleteGateHolderPath {
    param([string]$StateRoot)
    return (Join-Path $StateRoot 'gate-holder.json')
}

function Test-CodexSafeTreeDeleteGateHolderModeText {
    param([object]$Value)
    return ($Value -is [string] -and $Value -cmatch '^[A-Za-z][A-Za-z0-9-]{0,63}\z')
}

function Get-CodexSafeTreeDeleteGateHolderMode {
    # 只认 -Mode 参数（大小写不敏感；-Mode X、-Mode: X、-Mode:X）。缺失或值不合规时为 unknown。
    param([object[]]$Arguments = @())

    $values = @($Arguments)
    for ($index = 0; $index -lt $values.Count; $index++) {
        $token = $values[$index]
        if ($token -isnot [string]) { continue }
        if ($token -ieq '-Mode' -or $token -ieq '-Mode:') {
            $candidate = $(if ($index + 1 -lt $values.Count) { $values[$index + 1] } else { $null })
        } elseif ($token.StartsWith('-Mode:', [StringComparison]::OrdinalIgnoreCase)) {
            $candidate = $token.Substring(6)
        } else {
            continue
        }
        if (Test-CodexSafeTreeDeleteGateHolderModeText -Value $candidate) { return [string]$candidate }
        return 'unknown'
    }
    return 'unknown'
}

function Write-CodexSafeTreeDeleteGateHolder {
    # 持锁者取锁后调用。返回是否写成；任何失败都吞掉（有意降级，不阻塞调用）。
    param(
        [string]$StateRoot,
        [string]$Mode
    )

    $tempPath = $null
    try {
        $path = Get-CodexSafeTreeDeleteGateHolderPath -StateRoot $StateRoot
        $current = [Diagnostics.Process]::GetCurrentProcess()
        try {
            $processStartUtc = $current.StartTime.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        } finally {
            $current.Dispose()
        }
        $json = [ordered]@{
            pid = [int]$PID
            processStartUtc = $processStartUtc
            mode = $(if (Test-CodexSafeTreeDeleteGateHolderModeText -Value $Mode) { $Mode } else { 'unknown' })
            acquiredAtUtc = [datetime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        } | ConvertTo-Json -Compress -EscapeHandling EscapeNonAscii
        $tempPath = '{0}.{1}.{2}.tmp' -f $path, $PID, [guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllBytes($tempPath, [Text.Encoding]::ASCII.GetBytes($json))
        [IO.File]::Move($tempPath, $path, $true)
        $tempPath = $null
        return $true
    } catch {
        return $false
    } finally {
        if ($null -ne $tempPath) {
            try { [IO.File]::Delete($tempPath) } catch { }
        }
    }
}

function Remove-CodexSafeTreeDeleteGateHolder {
    # 持锁者在释放锁之前调用；失败吞掉（残留由读方 stale 判定与下一个持锁者的覆盖兜底）。
    param([string]$StateRoot)

    try {
        [IO.File]::Delete((Get-CodexSafeTreeDeleteGateHolderPath -StateRoot $StateRoot))
    } catch {
    }
}

function ConvertFrom-CodexSafeTreeDeleteGateHolderUtc {
    param([object]$Value)

    if ($Value -isnot [string] -or
        $Value -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{7}Z\z') {
        return $null
    }
    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($Value, 'o', [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
        return $null
    }
    return $parsed
}

function Test-CodexSafeTreeDeleteGateHolderStale {
    param(
        [int]$ProcessId,
        [datetime]$ProcessStartUtc
    )

    $process = $null
    try {
        $process = [Diagnostics.Process]::GetProcessById($ProcessId)
        if ($process.HasExited) { return $true }
        return ($process.StartTime.ToUniversalTime().Ticks -ne $ProcessStartUtc.Ticks)
    } catch {
        return $true
    } finally {
        if ($null -ne $process) { $process.Dispose() }
    }
}

function Read-CodexSafeTreeDeleteGateHolder {
    # 等锁超时方调用；永不抛出。只读打开并允许持锁者同时删除或替换。
    param([string]$StateRoot)

    $unknown = [ordered]@{ state = 'unknown' }
    try {
        $path = Get-CodexSafeTreeDeleteGateHolderPath -StateRoot $StateRoot
        $stream = [IO.FileStream]::new($path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try {
            if ($stream.Length -le 0 -or $stream.Length -gt 4096) { return $unknown }
            $bytes = [byte[]]::new([int]$stream.Length)
            $read = 0
            while ($read -lt $bytes.Length) {
                $count = $stream.Read($bytes, $read, $bytes.Length - $read)
                if ($count -le 0) { break }
                $read += $count
            }
        } finally {
            $stream.Dispose()
        }
        if ($read -ne $bytes.Length) { return $unknown }
        foreach ($byte in $bytes) {
            if ($byte -lt 0x20 -or $byte -gt 0x7E) { return $unknown }
        }
        $document = [Text.Encoding]::ASCII.GetString($bytes) | ConvertFrom-Json -AsHashtable -DateKind String
        if ($document -isnot [Collections.IDictionary]) { return $unknown }
        $processId = $document['pid']
        if (($processId -isnot [int] -and $processId -isnot [long]) -or
            $processId -lt 1 -or $processId -gt [int]::MaxValue) {
            return $unknown
        }
        $processStartUtc = ConvertFrom-CodexSafeTreeDeleteGateHolderUtc -Value $document['processStartUtc']
        $acquiredAtUtc = ConvertFrom-CodexSafeTreeDeleteGateHolderUtc -Value $document['acquiredAtUtc']
        $mode = $document['mode']
        if ($null -eq $processStartUtc -or $null -eq $acquiredAtUtc -or
            -not (Test-CodexSafeTreeDeleteGateHolderModeText -Value $mode)) {
            return $unknown
        }
        return [ordered]@{
            pid = [int]$processId
            mode = [string]$mode
            acquiredAtUtc = [string]$document['acquiredAtUtc']
            heldSeconds = [long][Math]::Max(0, [Math]::Floor(([datetime]::UtcNow - $acquiredAtUtc).TotalSeconds))
            stale = [bool](Test-CodexSafeTreeDeleteGateHolderStale -ProcessId ([int]$processId) -ProcessStartUtc $processStartUtc)
        }
    } catch {
        return $unknown
    }
}
