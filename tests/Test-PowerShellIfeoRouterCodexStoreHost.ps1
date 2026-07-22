param(
    [string]$CodexHome = "D:\Codex\.codex",
    [string]$RouterSource = "D:\Codex\local-overrides\codex-local-patches\powershell-ifeo-router\powershell-ifeo-router.ps1",
    [string]$RouterRuntime = "D:\Codex\.codex\powershell-ifeo-router",
    [string]$RouterDriftTask = "CodexPwshRouterDriftCheck"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-False {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        throw $Message
    }
}

$configPath = Join-Path $CodexHome "config.toml"
Assert-True -Condition (Test-Path -LiteralPath $configPath -PathType Leaf) -Message "找不到 Codex 配置：$configPath"
Assert-False -Condition (Test-Path -LiteralPath $RouterSource) -Message "已退役 router source 不得恢复：$RouterSource"
Assert-False -Condition (Test-Path -LiteralPath $RouterRuntime) -Message "已退役 router runtime 不得恢复：$RouterRuntime"

foreach ($registryPath in @(
    "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\powershell.exe",
    "HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\powershell.exe"
)) {
    Assert-False -Condition (Test-Path -LiteralPath $registryPath) -Message "已退役 router 不得保留 IFEO 注册：$registryPath"
}

$scheduledTask = $null
try {
    $scheduledTask = Get-ScheduledTask -TaskName $RouterDriftTask -ErrorAction Stop
} catch {
    $notFound = $_.Exception.Message -match "(?i)not found|cannot find|does not exist|no .*objects found|找不到|不存在"
    Assert-True -Condition $notFound -Message "无法确认已退役 router 计划任务状态：$($_.Exception.Message)"
}
Assert-True -Condition ($null -eq $scheduledTask) -Message "已退役 router 漂移任务不得保留：$RouterDriftTask"

$configText = Get-Content -Raw -LiteralPath $configPath
Assert-True -Condition ($configText -match '(?m)^integratedTerminalShell\s*=\s*"powershell"\s*$') -Message "Codex 必须使用现行 PowerShell 终端配置。"

[pscustomobject]@{
    ok = $true
    mode = "retired"
    integratedTerminalShell = "powershell"
    checkedAt = (Get-Date).ToString("o")
} | ConvertTo-Json -Depth 3
