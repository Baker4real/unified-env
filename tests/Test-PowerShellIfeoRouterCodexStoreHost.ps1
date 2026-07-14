param(
    [string]$RouterSource = "D:\Codex\local-overrides\codex-local-patches\powershell-ifeo-router\powershell-ifeo-router.ps1"
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

Assert-True -Condition (Test-Path -LiteralPath $RouterSource) -Message "找不到受管 router 源：$RouterSource"

$content = Get-Content -Raw -LiteralPath $RouterSource
$mainMarker = 'New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogPath)'
$mainIndex = $content.IndexOf($mainMarker, [System.StringComparison]::Ordinal)
Assert-True -Condition ($mainIndex -gt 0) -Message "无法定位 router 主执行段，不能安全加载测试 seam。"

$definitions = $content.Substring(0, $mainIndex)
Invoke-Expression $definitions

$officialStoreHost = [pscustomobject]@{
    Name = "ChatGPT.exe"
    ExecutablePath = "C:\Program Files\WindowsApps\OpenAI.Codex_26.707.3748.0_x64__2p2nqsd0c76g0\app\ChatGPT.exe"
    CommandLine = '"C:\Program Files\WindowsApps\OpenAI.Codex_26.707.3748.0_x64__2p2nqsd0c76g0\app\ChatGPT.exe"'
    ParentProcessId = 0
}

$sameNameOutsideStore = [pscustomobject]@{
    Name = "ChatGPT.exe"
    ExecutablePath = "D:\Codex\tmp\ChatGPT.exe"
    CommandLine = '"D:\Codex\tmp\ChatGPT.exe"'
    ParentProcessId = 0
}

$otherStorePackage = [pscustomobject]@{
    Name = "ChatGPT.exe"
    ExecutablePath = "C:\Program Files\WindowsApps\Other.Product_1.0.0.0_x64__example\app\ChatGPT.exe"
    CommandLine = '"C:\Program Files\WindowsApps\Other.Product_1.0.0.0_x64__example\app\ChatGPT.exe"'
    ParentProcessId = 0
}

Assert-True -Condition (Test-CodexProcessTree -StartProcess $officialStoreHost) -Message "官方 OpenAI.Codex Store 宿主应被允许进入固定 pwsh 转发链。"
Assert-False -Condition (Test-CodexProcessTree -StartProcess $sameNameOutsideStore) -Message "仅同名的非 Store ChatGPT.exe 不得被放行。"
Assert-False -Condition (Test-CodexProcessTree -StartProcess $otherStorePackage) -Message "其他 Store 包中的同名 ChatGPT.exe 不得被放行。"

[pscustomobject]@{
    ok = $true
    routerSource = $RouterSource
    checkedAt = (Get-Date).ToString("o")
} | ConvertTo-Json -Depth 3
