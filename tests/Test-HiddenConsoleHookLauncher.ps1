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
        -FilePath 'D:\Codex\tools\python315-official\pythonw.exe' `
        -ArgumentList (@('-I', '-S', '-B', '-X', 'utf8', $launcherPath, $TargetPath) + $TargetArguments) `
        -InputText $InputText `
        -Environment $Environment
}

function Invoke-CodexHostCommandProbe {
    param(
        [Parameter(Mandatory)][string]$CommandText,
        [AllowEmptyString()][string]$InputText = '',
        [hashtable]$Environment = @{}
    )

    Invoke-HiddenProcess `
        -FilePath 'D:\Codex\tools\PowerShell\7.6.5\pwsh.exe' `
        -ArgumentList @('-NoProfile', '-Command', $CommandText) `
        -InputText $InputText `
        -Environment $Environment
}

function ConvertTo-FixtureRemappedHookCommand {
    param(
        [Parameter(Mandatory)][string]$RenderedCommand,
        [Parameter(Mandatory)][string]$FixtureHooksRoot,
        [string[]]$ExtraArguments = @()
    )

    $livePrefix = 'D:\Codex\.codex\hooks\'
    $escapedLivePrefix = [regex]::Escape($livePrefix)
    $remapped = [regex]::Replace(
        $RenderedCommand,
        $escapedLivePrefix + '[^\s;]+',
        {
            param($Match)
            $relative = $Match.Value.Substring($livePrefix.Length)
            $target = Join-Path $FixtureHooksRoot $relative
            "'" + $target.Replace("'", "''") + "'"
        }
    )
    if ($ExtraArguments.Count -gt 0) {
        $suffix = ' ; exit $LASTEXITCODE'
        Assert-True ($remapped.EndsWith($suffix, [StringComparison]::Ordinal)) "渲染命令必须以 '$suffix' 结尾：$remapped"
        $quotedExtra = @($ExtraArguments | ForEach-Object { "'" + ([string]$_).Replace("'", "''") + "'" }) -join ' '
        $remapped = $remapped.Substring(0, $remapped.Length - $suffix.Length) + ' ' + $quotedExtra + $suffix
    }
    return $remapped
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
. (Join-Path $projectRoot 'scripts\lib\CodexHookPolicy.ps1')
. (Join-Path $projectRoot 'tests\lib\CodexHookLegacyFixtureTestSupport.ps1')
Assert-True (Assert-CodexHookRetiredCmdSourcesRemoved -ManagedRoot (Join-Path $projectRoot 'managed\codex-hooks')) '受管源码树必须零 .cmd 文件且全部 10 个已退役/历史 .cmd 均已移除。'
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
    -TargetPath 'D:\Codex\tools\PowerShell\7.6.5\pwsh.exe' `
    -TargetArguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $powerShellEncoded) `
    -InputText "probe-input`n"
Assert-ProtocolProbe -Result $powerShellResult -ExpectedExitCode 23 -ExpectedStderr 'direct-powershell-stderr'

$pythonProbe = 'import ctypes,json,sys; sys.stdout.write(json.dumps({"input":sys.stdin.readline().strip(),"windowHandle":ctypes.windll.kernel32.GetConsoleWindow()})); sys.stderr.write("direct-python-stderr"); raise SystemExit(24)'
$pythonResult = Invoke-LauncherProbe `
    -TargetPath 'D:\Codex\tools\python315-official\python.exe' `
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
    -FilePath 'D:\Codex\tools\PowerShell\7.6.5\pwsh.exe' `
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
    -FilePath 'D:\Codex\tools\python315-official\pythonw.exe' `
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
    -FilePath 'D:\Codex\tools\python315-official\python.exe' `
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

    $hostManifest = Read-CodexHookHostPreflightManifest
    $activateHook = @($hostManifest.hooks | Where-Object { $_.id -ceq 'serena-activate' })[0]
    $activateRendered = [string]((New-CodexHookCanonicalRegistryGroup -Hook $activateHook).hooks[0].command)
    Assert-True (
        $activateRendered -cmatch '^D:\\Codex\\tools\\python315-official\\python\.exe -I -S -B -X utf8 D:\\Codex\\\.codex\\hooks\\lib\\hidden-console-launcher\.py D:\\Codex\\tools\\PowerShell\\7\.6\.5\\pwsh\.exe ' -and
        $activateRendered.EndsWith(' ; exit $LASTEXITCODE', [StringComparison]::Ordinal)
    ) 'PowerShell direct-managed-launcher 必须按固定顺序使用 python.exe + 隔离 launcher flags + ; exit $LASTEXITCODE。'

    $powerShellImplementation = Join-Path $fixtureHooks 'serena-behavior-guard.ps1'
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
[Console]::Error.Write('direct-powershell-stderr')
exit 31
'@
    [IO.File]::WriteAllText($powerShellImplementation, $powerShellImplementationText, $utf8)
    $remappedActivateCommand = ConvertTo-FixtureRemappedHookCommand -RenderedCommand $activateRendered -FixtureHooksRoot $fixtureHooks
    $powerShellDirectResult = Invoke-CodexHostCommandProbe `
        -CommandText $remappedActivateCommand `
        -InputText "probe-input`n" `
        -Environment $probeEnvironment
    Assert-ProtocolProbe `
        -Result $powerShellDirectResult `
        -ExpectedExitCode 31 `
        -ExpectedStderr 'direct-powershell-stderr' `
        -ExpectedMode 'Activation'
    Assert-True (-not (Test-Path -LiteralPath $siteSentinel)) 'PowerShell direct-managed-launcher 的 python.exe launcher 加载了 PYTHONPATH/sitecustomize，-I/-S 隔离未生效。'

    $preflightHook = @($hostManifest.hooks | Where-Object { $_.id -ceq 'codex-state-preflight' })[0]
    $preflightRendered = [string]((New-CodexHookCanonicalRegistryGroup -Hook $preflightHook).hooks[0].command)
    Assert-True (
        $preflightRendered -cmatch '^D:\\Codex\\tools\\python315-official\\python\.exe -I -S -B -X utf8 D:\\Codex\\\.codex\\hooks\\lib\\hidden-console-launcher\.py D:\\Codex\\tools\\python315-official\\python\.exe -I -S -B -X utf8 D:\\Codex\\\.codex\\hooks\\codex-state-preflight\.py ; exit \$LASTEXITCODE$'
    ) 'Python direct-managed-launcher 必须按固定顺序使用两层隔离 flags + ; exit $LASTEXITCODE。'

    $pythonImplementation = Join-Path $fixtureHooks 'codex-state-preflight.py'
    $pythonImplementationText = @'
import ctypes
import json
import os
import sys

sys.stdout.write(json.dumps({
    "input": sys.stdin.readline().strip(),
    "windowHandle": ctypes.windll.kernel32.GetConsoleWindow(),
    "arguments": sys.argv[1:],
}))
sys.stderr.write("direct-python-stderr")
raise SystemExit(int(os.environ.get("CODEX_PROBE_EXIT_CODE", "32")))
'@
    [IO.File]::WriteAllText($pythonImplementation, $pythonImplementationText, $utf8)
    $expectedArguments = @('fixture argument with spaces', '--second')
    $remappedPreflightCommand = ConvertTo-FixtureRemappedHookCommand `
        -RenderedCommand $preflightRendered `
        -FixtureHooksRoot $fixtureHooks `
        -ExtraArguments $expectedArguments
    $pythonDirectResult = Invoke-CodexHostCommandProbe `
        -CommandText $remappedPreflightCommand `
        -InputText "probe-input`n" `
        -Environment $probeEnvironment
    Assert-ProtocolProbe `
        -Result $pythonDirectResult `
        -ExpectedExitCode 32 `
        -ExpectedStderr 'direct-python-stderr' `
        -ExpectedArguments $expectedArguments
    Assert-True (-not (Test-Path -LiteralPath $siteSentinel)) 'Python direct-managed-launcher 的 python.exe 加载了 PYTHONPATH/sitecustomize，-I/-S 隔离未生效。'

    $blockingEnv = $probeEnvironment.Clone()
    $blockingEnv['CODEX_PROBE_EXIT_CODE'] = '2'
    $blockingDirectResult = Invoke-CodexHostCommandProbe `
        -CommandText $remappedPreflightCommand `
        -InputText "probe-input`n" `
        -Environment $blockingEnv
    Assert-ProtocolProbe `
        -Result $blockingDirectResult `
        -ExpectedExitCode 2 `
        -ExpectedStderr 'direct-python-stderr' `
        -ExpectedArguments $expectedArguments

    $withoutExitSuffix = $remappedPreflightCommand.Substring(0, $remappedPreflightCommand.Length - ' ; exit $LASTEXITCODE'.Length)
    $flattenedResult = Invoke-CodexHostCommandProbe `
        -CommandText $withoutExitSuffix `
        -InputText "probe-input`n" `
        -Environment $blockingEnv
    Assert-True ($flattenedResult.exitCode -eq 1) "负向对照：缺少 ; exit `$LASTEXITCODE 时 pwsh -Command 应将退出码 2 压扁为 1（actual=$($flattenedResult.exitCode)）。"
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}

'ok=True'
