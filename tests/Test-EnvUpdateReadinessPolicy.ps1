param(
    [string]$ProjectRoot = "D:\Codex\projects\统一环境"
)

$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$policyPath = Join-Path $ProjectRoot "scripts\lib\EnvUpdateReadinessPolicy.ps1"
Assert-True (Test-Path -LiteralPath $policyPath -PathType Leaf) "找不到 EnvUpdateReadinessPolicy.ps1"
. $policyPath

$canonicalSharedRoots = @(Get-InventoryCanonicalSharedRoots)
Assert-True (($canonicalSharedRoots -join "|") -ceq "D:\Codex\tools|D:\Codex\envs|D:\uv") "canonical shared roots 漂移或函数缺失"

function New-OriginEvidence {
    param([string]$Path, [string]$OriginClass)
    $matchedRoot = if ($OriginClass -eq "shared-tool") {
        @(Get-InventoryCanonicalSharedRoots | Where-Object { Test-InventorySubPath -Path $Path -Root $_ } | Select-Object -First 1)[0]
    } elseif ($OriginClass -eq "unknown") { $null } else { [IO.Path]::GetDirectoryName($Path) }
    [pscustomobject]@{
        path = $Path
        originClass = $OriginClass
        matchedRule = if ($OriginClass -eq "shared-tool") { "explicit-shared-root" } else { "fixture" }
        matchedRoot = $matchedRoot
        metadataStatus = "ok"
        metadataError = $null
        isReparsePoint = $false
        reparseAncestor = $null
        reparseTarget = $null
    }
}

function New-ToolFact {
    param(
        [string]$Name,
        [string]$Path,
        [string]$OriginClass,
        [bool]$ProbeSucceeded,
        [bool]$RequiresManualReview = $false
    )
    $launcher = New-OriginEvidence -Path $Path -OriginClass $OriginClass
    [pscustomobject]@{
        name = $Name
        found = $true
        path = $Path
        version = if ($ProbeSucceeded) { "$Name fixture" } else { $null }
        probeSucceeded = $ProbeSucceeded
        error = if ($ProbeSucceeded) { $null } else { "fixture probe failed" }
        launcher = $launcher
        runtime = $null
        originClass = $OriginClass
        originEvidence = @([pscustomobject]@{ role = "launcher"; evidence = $launcher })
        resolutionScope = "process"
        requiresManualReview = $RequiresManualReview
    }
}

$cases = @(
    @{ name = "python"; path = "D:\projects\app\.venv\Scripts\python.exe"; origin = "project-local-env"; probe = $true; manual = $true; risk = "high"; entry = "Python"; forbidden = @("低风险", "共享运行时", "迁到 D 盘") }
    @{ name = "uv"; path = "D:\Codex\tools\uv\uv.exe"; origin = "shared-tool"; probe = $true; manual = $false; risk = "low"; entry = "uv"; forbidden = @("迁到 D 盘", "系统安装目录") }
    @{ name = "node"; path = "C:\Program Files\nodejs\node.exe"; origin = "system-installer"; probe = $true; manual = $true; risk = "medium"; entry = "Node.js"; forbidden = @("当前已在 D 盘") }
    @{ name = "npm"; path = "C:\Program Files\nodejs\npm.cmd"; origin = "system-installer"; probe = $true; manual = $true; risk = "medium"; entry = "Node.js"; forbidden = @("当前已在 D 盘") }
    @{ name = "cargo"; path = "D:\Codex\tools\rust\bin\cargo.exe"; origin = "shared-tool"; probe = $true; manual = $false; risk = "low"; entry = "rustup"; forbidden = @("系统安装目录", "迁到 D 盘") }
    @{ name = "rustc"; path = "D:\Codex\tools\rust\bin\rustc.exe"; origin = "shared-tool"; probe = $true; manual = $false; risk = "low"; entry = "rustup"; forbidden = @("系统安装目录", "迁到 D 盘") }
    @{ name = "dotnet"; path = "C:\Program Files\dotnet\dotnet.exe"; origin = "system-installer"; probe = $false; manual = $true; risk = "high"; entry = ".NET"; forbidden = @("当前已健康", "当前已在 D 盘") }
    @{ name = "cmake"; path = "C:\Users\tester\AppData\Local\Microsoft\WinGet\Packages\cmake.exe"; origin = "user-profile"; probe = $true; manual = $true; risk = "high"; entry = "CMake"; forbidden = @("当前已在 D 盘") }
    @{ name = "ninja"; path = "C:\Users\tester\AppData\Local\Microsoft\WinGet\Packages\ninja.exe"; origin = "user-profile"; probe = $true; manual = $true; risk = "high"; entry = "Ninja"; forbidden = @("当前已在 D 盘") }
    @{ name = "wsl"; path = "C:\Windows\System32\wsl.exe"; origin = "windows-system"; probe = $true; manual = $true; risk = "medium"; entry = "WSL"; forbidden = @("当前已在 D 盘") }
    @{ name = "git"; path = "C:\Program Files\Git\cmd\git.exe"; origin = "system-installer"; probe = $true; manual = $true; risk = "medium"; entry = "Git for Windows"; forbidden = @("当前已在 D 盘") }
    @{ name = "pwsh"; path = "D:\Codex\tools\PowerShell\7.6.4\pwsh.exe"; origin = "shared-tool"; probe = $true; manual = $false; risk = "low"; entry = "PowerShell"; forbidden = @("系统安装目录", "迁到 D 盘") }
    @{ name = "powershell"; path = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"; origin = "windows-system"; probe = $true; manual = $true; risk = "medium"; entry = "Windows"; forbidden = @("当前已在 D 盘") }
)

foreach ($case in $cases) {
    $tool = New-ToolFact -Name $case.name -Path $case.path -OriginClass $case.origin -ProbeSucceeded $case.probe -RequiresManualReview $case.manual
    $policy = Get-UpdatePolicy -Tool $tool
    Assert-True ($policy.decisionInputs.locationClass -eq (Get-ReadinessLocationClass -Path $case.path)) "$($case.name) locationClass 不一致"
    Assert-True ($policy.decisionInputs.originClass -eq $case.origin) "$($case.name) originClass 不一致"
    Assert-True ($policy.decisionInputs.probeSucceeded -is [bool] -and $policy.decisionInputs.probeSucceeded -eq $case.probe) "$($case.name) probeSucceeded 不一致"
    Assert-True ($policy.decisionInputs.requiresManualReview -is [bool] -and $policy.decisionInputs.requiresManualReview -eq $case.manual) "$($case.name) manual review 输入不一致"
    Assert-True ($policy.riskLevel -eq $case.risk) "$($case.name) risk 错误：$($policy.riskLevel)"
    Assert-True ($policy.requiresManualReview -eq $case.manual) "$($case.name) manual review 决策错误"
    Assert-True ($policy.recommendedUpdateEntry.Contains($case.entry)) "$($case.name) 更新入口错误"
    foreach ($forbidden in $case.forbidden) {
        Assert-True (-not $policy.recommendedUpdateEntry.Contains($forbidden)) "$($case.name) 工具专属入口包含位置断言：$forbidden"
        Assert-True (-not $policy.recommendedAction.Contains($forbidden)) "$($case.name) 建议与事实矛盾：$forbidden"
    }
}

$spoof = New-ToolFact -Name "spoof" -Path "D:\projects\app\.venv\Scripts\python.exe" -OriginClass "shared-tool" -ProbeSucceeded $true -RequiresManualReview $false
$spoof.launcher.matchedRule = "explicit-shared-root"
$spoof.launcher.matchedRoot = "D:\Codex\tools"
$spoof.originEvidence[0].evidence = $spoof.launcher
$spoofRejected = $false
try { Get-UpdatePolicy -Tool $spoof | Out-Null } catch { $spoofRejected = $true }
Assert-True $spoofRejected "Get-UpdatePolicy 直接调用也必须拒绝 project venv 伪报 shared-tool"

# Task2 producer 合法事实：canonical shared 归属仍可带 reparse 风险，策略必须 high/manual 而不是拒绝事实。
$sharedReparse = New-ToolFact -Name "shared-reparse" -Path "D:\Codex\tools\fixture\tool.exe" -OriginClass "shared-tool" -ProbeSucceeded $true -RequiresManualReview $true
$sharedReparse.launcher.isReparsePoint = $true
$sharedReparse.launcher.reparseAncestor = "D:\Codex\tools\fixture"
$sharedReparse.launcher.reparseTarget = "D:\target\fixture"
$sharedReparse.originEvidence[0].evidence = $sharedReparse.launcher
$sharedReparsePolicy = Get-UpdatePolicy -Tool $sharedReparse
Assert-True ($sharedReparsePolicy.riskLevel -eq "high" -and $sharedReparsePolicy.requiresManualReview) "shared reparse 必须 high/manual"
Assert-True ($sharedReparsePolicy.recommendedAction.Contains("D 盘共享") -and $sharedReparsePolicy.recommendedAction.Contains("reparse")) "shared reparse 必须同时保留归属与风险诊断"

# Task2 producer 合法事实：launcher 版本 probe 失败，但 Python runtime probe 成功并命中 canonical shared root。
$runtimeShared = New-ToolFact -Name "python" -Path "D:\Codex\tools\python-shim\python.exe" -OriginClass "unknown" -ProbeSucceeded $false -RequiresManualReview $true
$runtimeShared.launcher.matchedRule = "shared-root-probe-not-succeeded"
$runtimeShared.launcher.matchedRoot = "D:\Codex\tools"
$runtimeEvidence = New-OriginEvidence -Path "D:\Codex\tools\python\python.exe" -OriginClass "shared-tool"
$runtimeShared.runtime = $runtimeEvidence
$runtimeShared.originClass = "shared-tool"
$runtimeShared.originEvidence = @(
    [pscustomobject]@{ role = "launcher"; evidence = $runtimeShared.launcher },
    [pscustomobject]@{ role = "runtime"; evidence = $runtimeEvidence }
)
$runtimeSharedPolicy = Get-UpdatePolicy -Tool $runtimeShared
Assert-True ($runtimeSharedPolicy.riskLevel -eq "high" -and $runtimeSharedPolicy.requiresManualReview) "launcher probe 失败但 runtime shared 必须 high/manual"
Assert-True ($runtimeSharedPolicy.recommendedAction.Contains("D 盘共享") -and $runtimeSharedPolicy.recommendedAction.Contains("探测未成功")) "runtime shared 必须同时保留归属与 probe 诊断"

foreach ($origin in @("project-local-env", "vendor-runtime", "unknown")) {
    $tool = New-ToolFact -Name "probe-$origin" -Path "D:\fixture\tool.exe" -OriginClass $origin -ProbeSucceeded $false -RequiresManualReview $true
    $policy = Get-UpdatePolicy -Tool $tool
    Assert-True ($policy.riskLevel -eq "high" -and $policy.requiresManualReview) "$origin + probe failure 必须 high/manual"
    $originText = switch ($origin) { "project-local-env" { "项目本地环境" }; "vendor-runtime" { "vendor runtime" }; default { "归属未知" } }
    Assert-True $policy.recommendedAction.Contains($originText) "$origin + probe failure 必须保留高风险归属文案"
    Assert-True $policy.recommendedAction.Contains("探测未成功") "$origin + probe failure 必须叠加诊断文案"
}

$processScope = [pscustomobject]@{
    source = "process"
    readStatus = "ok"
    complete = $false
    errors = @("fixture incomplete")
    rawValueSha256 = ("0" * 64)
    dotNetValueSha256 = ("0" * 64)
    valuesMatch = $true
    readErrors = @()
    metadataErrors = @("fixture")
    entries = @([pscustomobject]@{ index = 0; rawPath = "D:\missing\.venv\Scripts"; expandedPath = "D:\missing\.venv\Scripts"; expansionStatus = "not-required"; exists = $false; drive = "D:\"; isReparsePoint = $false; reparseTarget = $null })
    duplicates = @()
    missingPathCleanupCandidates = @()
}
$summary = Get-ReadinessPathSummary -ProcessScope $processScope
Assert-True ($summary.sourceScope -eq "process") "PATH 摘要必须标记 process scope"
Assert-True (-not $summary.complete) "不完整 process scope 必须保持 complete=false"
Assert-True (-not $summary.cleanupAdviceAllowed) "不完整 process scope 不得允许清理建议"
Assert-True (@($summary.missingEntries).Count -eq 0) "不完整 process scope 不得生成 missing 建议"
Assert-True (@($summary.staleLocalEnvironmentEntries).Count -eq 0) "不完整 process scope 不得生成 stale 建议"
Assert-True ($summary.duplicates -is [array] -and $summary.duplicates.Count -eq 0) "不完整 process scope 的 duplicates 必须保持空数组"

$completeProcessScope = $processScope | ConvertTo-Json -Depth 20 | ConvertFrom-Json -DateKind String
$completeProcessScope.complete = $true
$completeProcessScope.errors = @()
$completeProcessScope.metadataErrors = @()
$completeSummary = Get-ReadinessPathSummary -ProcessScope $completeProcessScope
Assert-True ($completeSummary.duplicates -is [array] -and $completeSummary.duplicates.Count -eq 0) "完整 process scope 的空 duplicates 必须保持数组"

[pscustomobject]@{ ok = $true; cases = $cases.Count }
