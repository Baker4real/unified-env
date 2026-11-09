[CmdletBinding()]
param([string]$LockPath = 'D:/agents/skills-manager/.skills-manager.lock')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$processes = @(Get-Process | Where-Object { $_.ProcessName -in @('skills-manager','SkillsManager','skills_manager') } |
    ForEach-Object { [ordered]@{ name=$_.ProcessName; pid=$_.Id; status='running' } })
$lock = [ordered]@{ status='missing'; operation=$null; start_time=$null }
if (Test-Path -LiteralPath $LockPath -PathType Leaf) {
    try {
        if ((Get-Item -LiteralPath $LockPath).Length -gt 16384) { throw 'Oversized lock.' }
        $fields = @{}
        foreach ($line in [IO.File]::ReadAllLines($LockPath)) {
            if ($line -match '^(operation|start_time)=(.*)$') {
                if ($fields.ContainsKey($Matches[1])) { throw 'Duplicate lock field.' }
                $fields[$Matches[1]] = $Matches[2].Trim()
            }
        }
        $lock.status = 'missing-fields'
        if ($fields.ContainsKey('operation')) {
            if ($fields.operation -notmatch '^[A-Za-z][A-Za-z _-]{0,59}$') { throw 'Invalid lock operation.' }
            $lock.operation = $fields.operation
        }
        if ($fields.ContainsKey('start_time')) {
            $time = [DateTimeOffset]::MinValue
            if (-not [DateTimeOffset]::TryParse($fields.start_time, [ref]$time)) { throw 'Invalid lock start_time.' }
            $lock.start_time = $fields.start_time
        }
        if ($fields.ContainsKey('operation') -and $fields.ContainsKey('start_time')) {
            $lock.status = 'ok'
        }
    } catch { $lock.status = 'unreadable-or-invalid' }
}
[ordered]@{ schema_version=1; process_query_ok=$true; running=($processes.Count -gt 0);
    processes=$processes; lock=$lock } | ConvertTo-Json -Depth 5 -Compress
