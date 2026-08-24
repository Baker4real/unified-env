[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VendorPath,
    [Parameter(Mandatory)][string]$FixtureVendorScriptPath,
    [Parameter(Mandatory)][string]$RuntimePath,
    [Parameter(Mandatory)][string]$HealthRoot,
    [Parameter(Mandatory)][switch]$AllowFixture
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$fixtureVendor = 'D:\Codex\tools\PowerShell\7.6.5\pwsh.exe'
$fixtureVendorScript = 'D:\agents\projects\统一环境\reports\codex-hook-serena-fixture\serena-hooks-fixture.ps1'
$fixtureRuntime = 'D:\agents\projects\统一环境\managed\codex-hooks\hooks\lib\CodexHookRuntime.ps1'
$fixtureHealth = 'D:\agents\projects\统一环境\reports\codex-hook-health-test'
if (-not $AllowFixture -or $VendorPath -ine $fixtureVendor -or $FixtureVendorScriptPath -ine $fixtureVendorScript -or $RuntimePath -ine $fixtureRuntime -or $HealthRoot -ine $fixtureHealth) { throw 'Serena activate fixture capability 路径非法。' }
. $RuntimePath

$started=[DateTime]::UtcNow;$watch=[Diagnostics.Stopwatch]::StartNew();$input=[Console]::In.ReadToEnd()
$psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=$VendorPath;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
foreach($arg in @('-NoProfile','-File',$FixtureVendorScriptPath,'activate','--client=codex')){[void]$psi.ArgumentList.Add($arg)}
$p=[Diagnostics.Process]::new();$p.StartInfo=$psi;$buffer=[IO.MemoryStream]::new()
try{
    if(-not $p.Start()){throw 'fixture vendor 启动失败'}
    $copy=$p.StandardOutput.BaseStream.CopyToAsync($buffer);$stderrTask=$p.StandardError.ReadToEndAsync();$p.StandardInput.Write($input);$p.StandardInput.Close()
    $stderr=Complete-CodexHookProcessWithBoundedDrain -Process $p -StdoutTask $copy -StderrTask $stderrTask -TimeoutMilliseconds 5000 -ProcessName 'fixture vendor';[byte[]]$bytes=$buffer.ToArray()
    if($p.ExitCode -ne 0 -or -not[string]::IsNullOrWhiteSpace($stderr)){throw 'fixture vendor 失败'}
    Assert-CodexSerenaSessionStartOutputBytes -Bytes $bytes
    $watch.Stop();$health=[pscustomobject][ordered]@{hookId='serena-activate';runId=[guid]::NewGuid().ToString('N');startedAtUtc=$started.ToString('o');completedAtUtc=[DateTime]::UtcNow.ToString('o');durationMs=[long]$watch.ElapsedMilliseconds;ok=$true;changed=$false;restartRequired=$false;errors=[string[]]@()}
    Write-CodexHookLatestHealthCore -HookId 'serena-activate' -Payload $health -HealthRoot $HealthRoot -AllowFixtureRoot
    $stdout=[Console]::OpenStandardOutput();$stdout.Write($bytes,0,$bytes.Length);$stdout.Flush()
}catch{
    $watch.Stop();$health=[pscustomobject][ordered]@{hookId='serena-activate';runId=[guid]::NewGuid().ToString('N');startedAtUtc=$started.ToString('o');completedAtUtc=[DateTime]::UtcNow.ToString('o');durationMs=[long]$watch.ElapsedMilliseconds;ok=$false;changed=$false;restartRequired=$false;errors=[string[]]@('serena activate protocol validation failed')}
    Write-CodexHookLatestHealthCore -HookId 'serena-activate' -Payload $health -HealthRoot $HealthRoot -AllowFixtureRoot
    throw
}finally{$buffer.Dispose();$p.Dispose();$watch.Stop()}
