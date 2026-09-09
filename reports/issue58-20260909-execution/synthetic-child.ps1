param([ValidateSet('success','timeout','bad-json','pipe-timeout')][string]$Mode='success')
if ($Mode -eq 'timeout') { Start-Sleep -Seconds 30; exit 0 }
if ($Mode -eq 'bad-json') { [Console]::Write('{invalid'); exit 0 }
if ($Mode -eq 'pipe-timeout') {
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = [Environment]::ProcessPath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.Environment['ISSUE58_PARENT_PID']=[string]$PID
    foreach ($arg in @('-NoProfile','-File',(Join-Path $PSScriptRoot 'child-gate.ps1'),'-Payload',$PSCommandPath,'-PayloadArguments','timeout')) { [void]$psi.ArgumentList.Add($arg) }
    $p = [Diagnostics.Process]::Start($psi)
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while(-not [IO.File]::Exists((Join-Path $env:ISSUE58_RECEIPT_ROOT "$($p.Id).json")) -and $watch.ElapsedMilliseconds -lt 5000){Start-Sleep -Milliseconds 20}
    $p.StandardInput.WriteLine('GO');$p.StandardInput.Flush()
    [Console]::WriteLine('{"descendantPid":' + $p.Id + '}')
    exit 0
}
[Console]::Write('{"artifactType":"env-governance.codex-safe-tree-delete-status","schemaVersion":1,"complete":false,"operations":[{"operationId":"a"},{"operationId":"b"}]}')
