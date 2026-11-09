#requires -Version 7.4
[CmdletBinding()]
param(
    # 自习室在 Tailscale 登记的设备名；tailscale ping 按名字解析，仓库里不写地址。
    [string]$TargetHost = 'zi-xi-shi',
    [string]$EvidenceRoot = 'D:/agents/run-evidence/study-link'
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
Import-Module (Join-Path $PSScriptRoot 'RemoteOperations.psm1') -Force -ErrorAction Stop
$RemoteStepEntry = Join-Path $PSScriptRoot 'Invoke-RemoteStep.ps1'
$pingHandler = {
    $tailscale = Get-Command tailscale -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $psi = [Diagnostics.ProcessStartInfo]::new($tailscale.Source)
    foreach ($argument in @('ping', '--c', '1', '--timeout', '3s', $TargetHost)) { $psi.ArgumentList.Add($argument) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    $process = [Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(8000)) { $process.Kill($true) }
    $process.WaitForExit()
    $text = $stdout.GetAwaiter().GetResult()
    $success = $process.ExitCode -eq 0 -and $text -match 'pong from'
    [pscustomobject]@{
        success = $success
        connectionType = if (-not $success) { 'unreachable' } elseif ($text -match 'via DERP') { 'relay' } else { 'direct' }
    }
}
$sshHandler = {
    $runDirectory = Join-Path $EvidenceRoot ([guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $runDirectory -Force
    $identityScript = Join-Path $runDirectory 'identity.ps1'
    [IO.File]::WriteAllText($identityScript, "[ordered]@{ hostname = hostname; whoami = whoami } | ConvertTo-Json`n", $utf8)
    try {
        $global:LASTEXITCODE = 0
        & $RemoteStepEntry -Target study -ScriptPath $identityScript -TimeoutSeconds 15 | Out-Null
        $code = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
        [pscustomobject]@{ success = ($code -eq 0) }
    } catch {
        [pscustomobject]@{ success = $false }
    }
}
$result = Test-StudyLink -PingHandler $pingHandler -SshHandler $sshHandler
[ordered]@{
    status = $result.status
    connectionType = $result.connectionType
    sshSuccess = $result.sshSuccess
} | ConvertTo-Json -Compress
if ($result.status -ne 'online') { exit 1 }
