[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$managedRoot = Join-Path $projectRoot 'managed\antigravity-hooks'
$productionProjectRoot = 'D:\agents\projects\统一环境'
$registeredRoot = Join-Path $productionProjectRoot 'managed\antigravity-hooks'
$node = 'D:\Codex\tools\bin\node.exe'
$guardPath = Join-Path $managedRoot 'antigravity-pretool-guard.mjs'
$managedHooksPath = Join-Path $managedRoot 'hooks.json'
$liveHooksPath = Join-Path $env:USERPROFILE '.gemini\config\hooks.json'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Equal([object]$Actual, [object]$Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw "$Message actual=[$Actual] expected=[$Expected]" }
}

function Invoke-AntigravityGuard([AllowEmptyString()][string]$InputText, [switch]$ViaCmd) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
    $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    if ($ViaCmd) {
        $startInfo.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
        [void]$startInfo.ArgumentList.Add('/c')
        [void]$startInfo.ArgumentList.Add("$node $guardPath")
    } else {
        $startInfo.FileName = $node
        [void]$startInfo.ArgumentList.Add($guardPath)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        Assert-True $process.Start() "antigravity guard 无法启动：$guardPath"
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($InputText)
        $process.StandardInput.Close()
        Assert-True ($process.WaitForExit(15000)) 'antigravity guard 超时'
        return [pscustomobject]@{
            exitCode = $process.ExitCode
            stdout   = $stdoutTask.GetAwaiter().GetResult()
            stderr   = $stderrTask.GetAwaiter().GetResult()
        }
    } finally {
        $process.Dispose()
    }
}

Assert-True (Test-Path -LiteralPath $guardPath -PathType Leaf) '缺少 antigravity-pretool-guard.mjs。'
Assert-True (Test-Path -LiteralPath $managedHooksPath -PathType Leaf) '缺少受管 hooks.json。'

$selfTest = & $node $guardPath --self-test
Assert-Equal $LASTEXITCODE 0 "antigravity guard --self-test 必须成功：$selfTest"

# 验证 Antigravity hooks.json 结构（pwsh-preflight-guard 与 pretool-guard 共存）及与 live 副本一致。
$managedJson = Get-Content -LiteralPath $managedHooksPath -Raw -Encoding utf8 | ConvertFrom-Json
$pwshEntry = $managedJson.'pwsh-preflight-guard'.PreToolUse[0]
Assert-Equal $pwshEntry.matcher 'run_command' 'pwsh-preflight-guard matcher 不符'
Assert-Equal $pwshEntry.hooks[0].command 'python -B -X utf8 D:/Codex/.codex/scripts/antigravity_pretool_guard.py' 'pwsh-preflight-guard command 不符'
$entry = $managedJson.'pretool-guard'.PreToolUse[0]
Assert-Equal $entry.matcher 'run_command|write_file|edit_file|write_to_file|replace_file_content' 'matcher 不符'
$expectedCommand = "$node $(Join-Path $registeredRoot 'antigravity-pretool-guard.mjs')"
Assert-Equal $entry.hooks[0].command $expectedCommand 'command 必须指向正式受管 guard'

if (Test-Path -LiteralPath $liveHooksPath -PathType Leaf) {
    $liveRaw = (Get-Content -LiteralPath $liveHooksPath -Raw -Encoding utf8).Trim()
    $managedRaw = (Get-Content -LiteralPath $managedHooksPath -Raw -Encoding utf8).Trim()
    Assert-Equal $liveRaw $managedRaw 'live ~/.gemini/config/hooks.json 与受管源不一致'
}

# 验证 cmd /c 路径（与 Antigravity Windows 实际调用方式一致）的 deny / allow / 异常 JSON 容错。
$denyCases = @(
    @{ toolCall = @{ name = 'run_command'; args = @{ CommandLine = 'rg -n foo D:\agents\x\*.js' } }; cwd = 'D:\agents\projects\misc' },
    @{ toolCall = @{ name = 'run_command'; args = @{ CommandLine = 'Remove-Item -Recurse -Force D:\tmp\x' } }; cwd = 'D:\agents\projects\misc' },
    @{ toolCall = @{ name = 'run_command'; args = @{ CommandLine = 'Get-Item . ; exit 0' } }; cwd = 'D:\agents\projects\misc' },
    @{ toolCall = @{ name = 'write_file'; args = @{ Path = 'D:\agents\skills-manager\skills\retro\SKILL.md'; Content = 'x' } }; cwd = 'D:\agents\projects\misc' }
)
foreach ($case in $denyCases) {
    $res = Invoke-AntigravityGuard ($case | ConvertTo-Json -Depth 6 -Compress) -ViaCmd
    Assert-Equal $res.exitCode 0 "deny 路径必须 exit 0，stderr=$($res.stderr)"
    $out = $res.stdout | ConvertFrom-Json
    Assert-Equal $out.decision 'deny' "必须拦截：$($case | ConvertTo-Json -Depth 6 -Compress)"
    Assert-True ([string]::IsNullOrWhiteSpace($out.reason) -eq $false) 'deny 必须提供 reason'
}

$allowCases = @(
    @{ toolCall = @{ name = 'run_command'; args = @{ CommandLine = "rg -n foo D:\agents\projects\home-network -g '*.js'" } }; cwd = 'D:\agents\projects\misc' },
    @{ toolCall = @{ name = 'run_command'; args = @{ CommandLine = 'git status --short' } }; cwd = 'D:\agents\projects\misc' },
    @{ toolCall = @{ name = 'edit_file'; args = @{ Path = 'D:\agents\projects\home-network\AGENTS.md'; Target = 'a'; Replacement = 'b' } }; cwd = 'D:\agents\projects\misc' }
)
foreach ($case in $allowCases) {
    $res = Invoke-AntigravityGuard ($case | ConvertTo-Json -Depth 6 -Compress) -ViaCmd
    Assert-Equal $res.exitCode 0 "allow 路径必须 exit 0，stderr=$($res.stderr)"
    $out = $res.stdout | ConvertFrom-Json
    Assert-Equal $out.decision 'allow' "必须放行：$($case | ConvertTo-Json -Depth 6 -Compress)"
}

$malformed = Invoke-AntigravityGuard '{not-json' -ViaCmd
Assert-Equal $malformed.exitCode 0 '畸形 JSON 必须 fail-open 并 exit 0'
Assert-Equal (($malformed.stdout | ConvertFrom-Json).decision) 'allow' '畸形 JSON 必须返回 allow'

# 验证带 AGENTS-SYNC:GENERATED 头的全局规则生成物经 edit_file / write_file 被拦截，普通文件放行。
$tempGenDir = Join-Path ([IO.Path]::GetTempPath()) ('agy-guard-gen-' + [guid]::NewGuid().ToString('N'))
$tempGenFile = Join-Path $tempGenDir 'AGENTS.md'
[void][IO.Directory]::CreateDirectory($tempGenDir)
try {
    [IO.File]::WriteAllText($tempGenFile, "<!-- AGENTS-SYNC:GENERATED v2 -->`n# Antigravity Rules`n", [Text.UTF8Encoding]::new($false))
    $genEdit = Invoke-AntigravityGuard (@{ toolCall = @{ name = 'edit_file'; args = @{ Path = $tempGenFile; Target = 'Antigravity'; Replacement = 'Edited' } }; cwd = $tempGenDir } | ConvertTo-Json -Depth 6 -Compress) -ViaCmd
    Assert-Equal $genEdit.exitCode 0 '生成物 edit_file deny 必须 exit 0'
    $genOut = $genEdit.stdout | ConvertFrom-Json
    Assert-Equal $genOut.decision 'deny' '带 AGENTS-SYNC:GENERATED 头的 edit_file 必须被拦截'
    Assert-True ($genOut.reason.Contains('Manual-Sync-AgentsMd.ps1')) '拒绝原因必须指向 Manual-Sync-AgentsMd.ps1'
} finally {
    if (Test-Path -LiteralPath $tempGenFile) { Remove-Item -LiteralPath $tempGenFile }
    if (Test-Path -LiteralPath $tempGenDir) { [IO.Directory]::Delete($tempGenDir) }
}

Write-Output 'Test-AntigravityHostHooks passed.'
