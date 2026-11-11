#requires -Version 7.4
<#
.SYNOPSIS
在 office/study 以 stdin 执行本地 Python 脚本，复用同目录 Invoke-RemoteStep.ps1 的业务门禁。
.DESCRIPTION
远端 Python 能执行任意代码，所以一律按写操作处理：生成的远端脚本首条语句断言
CODEX_REMOTE_EXECUTION_TARGET，并经 -WriteOperation 交给 helper 在连接前校验。
Python 参数与源文件路径以 Base64 嵌入生成的脚本，不拼进引号。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('office', 'study')][string]$Target,
    [Parameter(Mandatory)][string]$PythonScriptPath,
    [string[]]$PythonArgument = @(),
    [string]$OutputPath,
    [int]$TimeoutSeconds = 300,
    [string]$PythonExecutable = 'D:/Codex/tools/python314-official/python.exe',
    [switch]$IncludeOutput,
    [ValidateRange(1, 1048576)][int]$MaxOutputChars = 6000,
    [string]$EvidenceRoot = 'D:/agents/run-evidence/remote-python'
)
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$stepEntry = Join-Path $PSScriptRoot 'Invoke-RemoteStep.ps1'
if (-not (Test-Path -LiteralPath $stepEntry -PathType Leaf)) { throw 'Invoke-RemoteStep.ps1 is missing next to Invoke-RemotePython.ps1' }
$sourcePath = (Resolve-Path -LiteralPath $PythonScriptPath).ProviderPath
$runDirectory = Join-Path $EvidenceRoot ([guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $runDirectory -Force
$remoteScript = Join-Path $runDirectory 'Remote-Python.ps1'
$stdinScript = Join-Path $runDirectory 'Emit-Python.ps1'
if (-not $OutputPath) { $OutputPath = Join-Path $runDirectory 'result.out.txt' }
$argumentBase64 = [Convert]::ToBase64String($utf8.GetBytes((ConvertTo-Json -InputObject @($PythonArgument) -AsArray -Compress)))
$pythonBase64 = [Convert]::ToBase64String($utf8.GetBytes($PythonExecutable))
$remoteBody = @'
if ($env:CODEX_REMOTE_EXECUTION_TARGET -ne '__TARGET__') { throw 'Remote execution context required: __TARGET__' }
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$source = [Console]::In.ReadToEnd()
$additionalArguments = ConvertFrom-Json -InputObject ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__ARGUMENTS_BASE64__')))
$pythonExecutable = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PYTHON_BASE64__'))
$psi = [Diagnostics.ProcessStartInfo]::new($pythonExecutable)
foreach ($argument in @('-B', '-I', '-X', 'utf8', '-') + @($additionalArguments)) { $psi.ArgumentList.Add([string]$argument) }
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.StandardInputEncoding = $utf8
$psi.StandardOutputEncoding = $utf8
$psi.StandardErrorEncoding = $utf8
$process = [Diagnostics.Process]::Start($psi)
$stdoutTask = $process.StandardOutput.ReadToEndAsync()
$stderrTask = $process.StandardError.ReadToEndAsync()
$process.StandardInput.Write($source)
$process.StandardInput.Close()
$process.WaitForExit()
[Console]::Out.Write($stdoutTask.GetAwaiter().GetResult())
[Console]::Error.Write($stderrTask.GetAwaiter().GetResult())
exit $process.ExitCode
'@.Replace('__TARGET__', $Target).Replace('__ARGUMENTS_BASE64__', $argumentBase64).Replace('__PYTHON_BASE64__', $pythonBase64)
[IO.File]::WriteAllText($remoteScript, $remoteBody, $utf8)
# 发射脚本在本机由 helper 运行，把 Python 源码写进远端 stdin。
$sourceBase64 = [Convert]::ToBase64String($utf8.GetBytes($sourcePath))
$emitterBody = "[IO.File]::ReadAllText([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$sourceBase64')))`n"
[IO.File]::WriteAllText($stdinScript, $emitterBody, $utf8)
$stepArguments = @{
    Target = $Target
    ScriptPath = $remoteScript
    StdinScript = $stdinScript
    OutputPath = $OutputPath
    TimeoutSeconds = $TimeoutSeconds
    WriteOperation = $true
    IncludeOutput = $IncludeOutput
    MaxOutputChars = $MaxOutputChars
}
$global:LASTEXITCODE = 0
& $stepEntry @stepArguments
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
