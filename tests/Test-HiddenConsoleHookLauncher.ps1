Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Invoke-HiddenProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [AllowEmptyString()][string]$RawArguments,
        [AllowEmptyString()][string]$InputText = '',
        [hashtable]$Environment = @{}
    )

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FilePath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    if ($PSBoundParameters.ContainsKey('RawArguments')) {
        $start.Arguments = $RawArguments
    } else {
        foreach ($argument in $ArgumentList) { [void]$start.ArgumentList.Add($argument) }
    }
    foreach ($name in $Environment.Keys) { $start.Environment[[string]$name] = [string]$Environment[$name] }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $started = $false
    try {
        $started = $process.Start()
        Assert-True $started "进程无法启动：$FilePath"
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($InputText)
        $process.StandardInput.Close()
        Assert-True ($process.WaitForExit(10000)) "进程超过10秒：$FilePath"
        [pscustomobject]@{
            exitCode = $process.ExitCode
            stdout = $stdoutTask.GetAwaiter().GetResult()
            stderr = $stderrTask.GetAwaiter().GetResult()
        }
    }
    finally {
        if ($started -and -not $process.HasExited) { try { $process.Kill($true) } catch {} }
        $process.Dispose()
    }
}

function Invoke-LauncherProbe {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [string[]]$TargetArguments = @(),
        [AllowEmptyString()][string]$InputText = '',
        [hashtable]$Environment = @{}
    )

    Invoke-HiddenProcess `
        -FilePath 'D:\Codex\tools\python314-official\pythonw.exe' `
        -ArgumentList (@('-I', '-S', '-B', '-X', 'utf8', $launcherPath, $TargetPath) + $TargetArguments) `
        -InputText $InputText `
        -Environment $Environment
}

function Invoke-WrapperProbe {
    param(
        [Parameter(Mandatory)][string]$WrapperPath,
        [string[]]$ArgumentList = @(),
        [AllowEmptyString()][string]$InputText = '',
        [hashtable]$Environment = @{}
    )

    $quotedArguments = @($ArgumentList | ForEach-Object { '"' + ([string]$_).Replace('"', '""') + '"' }) -join ' '
    $rawArguments = '/d /s /c ""' + $WrapperPath + '" ' + $quotedArguments + '"'
    Invoke-HiddenProcess `
        -FilePath 'C:\Windows\System32\cmd.exe' `
        -RawArguments $rawArguments `
        -InputText $InputText `
        -Environment $Environment
}

function Assert-ProtocolProbe {
    param(
        [Parameter(Mandatory)][object]$Result,
        [Parameter(Mandatory)][int]$ExpectedExitCode,
        [Parameter(Mandatory)][string]$ExpectedStderr,
        [string]$ExpectedMode,
        [string[]]$ExpectedArguments
    )

    Assert-True ($Result.exitCode -eq $ExpectedExitCode) "退出码未透传：expected=$ExpectedExitCode, actual=$($Result.exitCode), stderr=$($Result.stderr)"
    Assert-True ($Result.stderr.Contains($ExpectedStderr, [StringComparison]::Ordinal)) "stderr 未透传 sentinel：expected=$ExpectedStderr, actual=$($Result.stderr)"
    $protocol = $Result.stdout | ConvertFrom-Json
    Assert-True ($protocol.input -ceq 'probe-input') "target 未继承 stdin：stdout=$($Result.stdout)"
    Assert-True ([int64]$protocol.windowHandle -eq 0) "target 仍分配了 console window：stdout=$($Result.stdout)"
    if ($PSBoundParameters.ContainsKey('ExpectedMode')) {
        Assert-True ($protocol.mode -ceq $ExpectedMode) "wrapper 未透传固定 mode：expected=$ExpectedMode, actual=$($protocol.mode)"
    }
    if ($PSBoundParameters.ContainsKey('ExpectedArguments')) {
        Assert-True ((@($protocol.arguments) -join "`n") -ceq ($ExpectedArguments -join "`n")) "wrapper 未逐项透传参数：actual=$(@($protocol.arguments) -join ',')"
    }
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$launcherPath = Join-Path $projectRoot 'managed\codex-hooks\hooks\lib\hidden-console-launcher.py'
Assert-True (Test-Path -LiteralPath $launcherPath -PathType Leaf) '缺少 hidden console launcher。'

$powerShellProbe = @'
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class ConsoleWindowProbe {
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
}
"@
$result = [ordered]@{
    input = [Console]::In.ReadLine()
    windowHandle = [ConsoleWindowProbe]::GetConsoleWindow().ToInt64()
}
[Console]::Out.Write(($result | ConvertTo-Json -Compress))
[Console]::Error.Write('direct-powershell-stderr')
exit 23
'@
$powerShellEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($powerShellProbe))
$powerShellResult = Invoke-LauncherProbe `
    -TargetPath 'D:\Codex\tools\PowerShell\7.6.4\pwsh.exe' `
    -TargetArguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $powerShellEncoded) `
    -InputText "probe-input`n"
Assert-ProtocolProbe -Result $powerShellResult -ExpectedExitCode 23 -ExpectedStderr 'direct-powershell-stderr'

$pythonProbe = 'import ctypes,json,sys; sys.stdout.write(json.dumps({"input":sys.stdin.readline().strip(),"windowHandle":ctypes.windll.kernel32.GetConsoleWindow()})); sys.stderr.write("direct-python-stderr"); raise SystemExit(24)'
$pythonResult = Invoke-LauncherProbe `
    -TargetPath 'D:\Codex\tools\python314-official\python.exe' `
    -TargetArguments @('-I', '-S', '-B', '-X', 'utf8', '-c', $pythonProbe) `
    -InputText "probe-input`n"
Assert-ProtocolProbe -Result $pythonResult -ExpectedExitCode 24 -ExpectedStderr 'direct-python-stderr'

$startJobProbe = @'
$job = Start-Job -ScriptBlock {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class JobConsoleWindowProbe {
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
}
"@
    [pscustomobject]@{
        processId = $PID
        windowHandle = [JobConsoleWindowProbe]::GetConsoleWindow().ToInt64()
    }
}
try {
    $completedJob = Wait-Job -Job $job -Timeout 10
    if ($null -eq $completedJob) { throw 'Start-Job probe timed out' }
    $jobResult = Receive-Job -Job $job -ErrorAction Stop
    if ($job.State -cne 'Completed') { throw "Start-Job probe failed: $($job.State)" }
    [Console]::Out.Write(([ordered]@{
        parentProcessId = $PID
        jobProcessId = [int]$jobResult.processId
        jobWindowHandle = [int64]$jobResult.windowHandle
    } | ConvertTo-Json -Compress))
}
finally {
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
}
'@
$startJobEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($startJobProbe))
$startJobResult = Invoke-HiddenProcess `
    -FilePath 'D:\Codex\tools\PowerShell\7.6.4\pwsh.exe' `
    -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $startJobEncoded)
Assert-True ($startJobResult.exitCode -eq 0) "Start-Job hidden parent 探针失败：exit=$($startJobResult.exitCode), stderr=$($startJobResult.stderr)"
Assert-True ([string]::IsNullOrWhiteSpace($startJobResult.stderr)) "Start-Job hidden parent 探针产生 stderr：$($startJobResult.stderr)"
$startJobProtocol = $startJobResult.stdout | ConvertFrom-Json
Assert-True ([int]$startJobProtocol.jobProcessId -ne [int]$startJobProtocol.parentProcessId) 'Start-Job 探针必须来自独立子进程。'
Assert-True ([int64]$startJobProtocol.jobWindowHandle -eq 0) "CreateNoWindow pwsh 创建的 Start-Job 仍分配了 console window：$($startJobResult.stdout)"

$missingTarget = Join-Path $projectRoot ('.scratch\missing-hidden-target-' + [guid]::NewGuid().ToString('N') + '.exe')
$missingResult = Invoke-LauncherProbe -TargetPath $missingTarget
Assert-True ($missingResult.exitCode -eq 127) "launcher 启动不存在的 target 时必须返回 127：$($missingResult.exitCode)"
Assert-True ($missingResult.stderr -cmatch 'FileNotFoundError: \[WinError 2\]') "launcher 启动失败必须在 stderr 给出稳定诊断：$($missingResult.stderr)"

$missingArgumentsResult = Invoke-HiddenProcess `
    -FilePath 'D:\Codex\tools\python314-official\pythonw.exe' `
    -ArgumentList @('-I', '-S', '-B', '-X', 'utf8', $launcherPath)
Assert-True ($missingArgumentsResult.exitCode -eq 127) "launcher 缺少 target 时必须返回 127：$($missingArgumentsResult.exitCode)"
Assert-True ($missingArgumentsResult.stderr -cmatch 'ValueError: target executable is required') "launcher 缺少 target 时必须在 stderr 给出稳定诊断：$($missingArgumentsResult.stderr)"

$invalidStdoutProbe = @'
import ctypes
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("hidden_console_launcher", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
ctypes.windll.kernel32.SetStdHandle(-11, ctypes.c_void_p(1))
raise SystemExit(module.main([sys.executable, "-I", "-S", "-B", "-X", "utf8", "-c", "pass"]))
'@
$invalidStdoutResult = Invoke-HiddenProcess `
    -FilePath 'D:\Codex\tools\python314-official\python.exe' `
    -ArgumentList @('-I', '-S', '-B', '-X', 'utf8', '-c', $invalidStdoutProbe, $launcherPath)
Assert-True ($invalidStdoutResult.exitCode -eq 127) "launcher 标准句柄初始化失败时必须返回 127：$($invalidStdoutResult.exitCode)"
Assert-True ($invalidStdoutResult.stderr -cmatch 'OSError: \[WinError 6\]') "launcher 标准句柄初始化失败时必须尽力写入 stderr：$($invalidStdoutResult.stderr)"

$fixtureRoot = Join-Path $projectRoot ('.scratch\hidden console launcher chain-' + [guid]::NewGuid().ToString('N'))
$fixtureHooks = Join-Path $fixtureRoot 'hooks'
$fixtureLauncher = Join-Path $fixtureHooks 'lib\hidden-console-launcher.py'
$siteRoot = Join-Path $fixtureRoot 'python-path-injection'
$siteSentinel = Join-Path $fixtureRoot 'sitecustomize-loaded.txt'
$utf8 = [Text.UTF8Encoding]::new($false)
try {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $fixtureLauncher), $siteRoot | Out-Null
    Copy-Item -LiteralPath $launcherPath -Destination $fixtureLauncher

    $sitecustomize = @'
import os
from pathlib import Path
import sys

if Path(sys.executable).name.lower() in {"pythonw.exe", "python.exe"}:
    Path(os.environ["CODEX_SITE_SENTINEL"]).write_text("loaded", encoding="utf-8")
'@
    [IO.File]::WriteAllText((Join-Path $siteRoot 'sitecustomize.py'), $sitecustomize, $utf8)
    $probeEnvironment = @{
        PYTHONPATH = $siteRoot
        CODEX_SITE_SENTINEL = $siteSentinel
    }

    $powerShellWrapper = Join-Path $fixtureHooks 'serena-activation-reminder.cmd'
    $powerShellImplementation = Join-Path $fixtureHooks 'serena-behavior-guard.ps1'
    Copy-Item -LiteralPath (Join-Path $projectRoot 'managed\codex-hooks\hooks\serena-activation-reminder.cmd') -Destination $powerShellWrapper
    $powerShellWrapperText = Get-Content -LiteralPath $powerShellWrapper -Raw
    Assert-True ($powerShellWrapperText -cmatch 'pythonw\.exe" -I -S -B -X utf8 "%~dp0lib\\hidden-console-launcher\.py"') 'PowerShell wrapper 必须按固定顺序使用隔离 launcher flags。'
    $powerShellImplementationText = @'
param([string]$Mode)
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class FixtureConsoleWindowProbe {
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
}
"@
$result = [ordered]@{
    input = [Console]::In.ReadLine()
    windowHandle = [FixtureConsoleWindowProbe]::GetConsoleWindow().ToInt64()
    mode = $Mode
}
[Console]::Out.Write(($result | ConvertTo-Json -Compress))
[Console]::Error.Write('wrapper-powershell-stderr')
exit 31
'@
    [IO.File]::WriteAllText($powerShellImplementation, $powerShellImplementationText, $utf8)
    $powerShellWrapperResult = Invoke-WrapperProbe `
        -WrapperPath $powerShellWrapper `
        -InputText "probe-input`n" `
        -Environment $probeEnvironment
    Assert-ProtocolProbe `
        -Result $powerShellWrapperResult `
        -ExpectedExitCode 31 `
        -ExpectedStderr 'wrapper-powershell-stderr' `
        -ExpectedMode 'Activation'
    Assert-True (-not (Test-Path -LiteralPath $siteSentinel)) 'PowerShell wrapper 的 pythonw launcher 加载了 PYTHONPATH/sitecustomize，-I/-S 隔离未生效。'

    $pythonWrapper = Join-Path $fixtureHooks 'codex-state-preflight.cmd'
    $pythonImplementation = Join-Path $fixtureHooks 'codex-state-preflight.py'
    Copy-Item -LiteralPath (Join-Path $projectRoot 'managed\codex-hooks\hooks\codex-state-preflight.cmd') -Destination $pythonWrapper
    $pythonWrapperText = Get-Content -LiteralPath $pythonWrapper -Raw
    Assert-True ($pythonWrapperText -cmatch 'pythonw\.exe" -I -S -B -X utf8 "%~dp0lib\\hidden-console-launcher\.py"') 'Python wrapper 必须按固定顺序使用隔离 launcher flags。'
    Assert-True ($pythonWrapperText -cmatch 'python\.exe" -I -S -B -X utf8 "%~dp0codex-state-preflight\.py"') 'Python wrapper 的最终 runtime 必须按固定顺序使用隔离 flags。'
    $pythonImplementationText = @'
import ctypes
import json
import sys

sys.stdout.write(json.dumps({
    "input": sys.stdin.readline().strip(),
    "windowHandle": ctypes.windll.kernel32.GetConsoleWindow(),
    "arguments": sys.argv[1:],
}))
sys.stderr.write("wrapper-python-stderr")
raise SystemExit(32)
'@
    [IO.File]::WriteAllText($pythonImplementation, $pythonImplementationText, $utf8)
    $expectedArguments = @('fixture argument with spaces', '--second')
    $pythonWrapperResult = Invoke-WrapperProbe `
        -WrapperPath $pythonWrapper `
        -ArgumentList $expectedArguments `
        -InputText "probe-input`n" `
        -Environment $probeEnvironment
    Assert-ProtocolProbe `
        -Result $pythonWrapperResult `
        -ExpectedExitCode 32 `
        -ExpectedStderr 'wrapper-python-stderr' `
        -ExpectedArguments $expectedArguments
    Assert-True (-not (Test-Path -LiteralPath $siteSentinel)) 'Python wrapper 的 pythonw launcher 加载了 PYTHONPATH/sitecustomize，-I/-S 隔离未生效。'
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}

'ok=True'
