[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$outDir = 'D:\Codex\projects\统一环境\reports\safe-tree-delete-issue35-livefs-20260815'
$testPath = 'D:\Codex\projects\统一环境\tests\Test-CodexSafeTreeDeleteFileSystem.ps1'
$pwsh = 'D:\Codex\tools\PowerShell\7.6.4\pwsh.exe'
$stdoutPath = Join-Path $outDir 'elevated-filesystem.stdout.txt'
$stderrPath = Join-Path $outDir 'elevated-filesystem.stderr.txt'
$metaPath = Join-Path $outDir 'elevated-filesystem.meta.json'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    $denied = [pscustomobject][ordered]@{
        capturedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
        elevatedProcessIsAdministrator = $false
        user = $identity.Name
        exitCode = 740
        reason = '此脚本必须在已提权的 PowerShell 7 中运行。当前进程不是 Administrator，未调用 diskpart。'
    }
    $denied | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $metaPath -Encoding utf8
    Write-Error $denied.reason
    exit 740
}

$started = [datetimeoffset]::UtcNow
$process = Start-Process -FilePath $pwsh -ArgumentList @(
    '-NoProfile',
    '-NonInteractive',
    '-File',
    $testPath
) -WorkingDirectory 'D:\Codex\projects\统一环境' -Wait -PassThru -NoNewWindow `
    -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
$ended = [datetimeoffset]::UtcNow

[pscustomobject][ordered]@{
    capturedAtUtc = $ended.ToString('o')
    elevatedProcessIsAdministrator = $isAdmin
    user = $identity.Name
    testPath = $testPath
    exitCode = [int]$process.ExitCode
    startedAtUtc = $started.ToString('o')
    endedAtUtc = $ended.ToString('o')
    wallClockSeconds = [math]::Round(($ended - $started).TotalSeconds, 3)
    stdoutPath = $stdoutPath
    stderrPath = $stderrPath
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $metaPath -Encoding utf8

exit [int]$process.ExitCode
