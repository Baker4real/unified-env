param([switch]$Enabled)
$ErrorActionPreference='Stop'
$env:CODEX_SAFE_TREE_DELETE_STATUS_DEBUG_OP_TIMING=if($Enabled){'1'}else{$null}
Add-Type -Path 'D:/agents/projects/统一环境/scripts/lib/CodexSafeTreeDeleteStatusScan.cs'
$scratch=Join-Path 'D:/agents/projects/统一环境/.scratch' ('safe-tree-delete-tests-issue58-leaf-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($scratch)
for($i=0;$i -lt 12;$i++){[IO.File]::WriteAllText((Join-Path $scratch "$i.txt"),'fixture')}
$result=[CodexSafeTreeDelete.StatusTreeSnapshotScanner]::Scan($scratch,$false,$false,$null)
$type=[CodexSafeTreeDelete.StatusTreeSnapshotScanner]
$expectedCalls=if($Enabled){12}else{0}
$pass=$result.Entries.Count -eq 13 -and $result.FileContentBytes -eq 84 -and $type::DiagnosticEnabled -eq [bool]$Enabled -and $type::DiagnosticLeafCalls -eq $expectedCalls -and $type::DiagnosticActiveLeaves -eq 0
if($Enabled){$pass=$pass -and $type::DiagnosticPeakLeaves -ge 1 -and $type::DiagnosticPeakLeaves -le 12 -and $type::DiagnosticLeafWorkMs -gt 0}
$record=@{passed=$pass;enabled=[bool]$Enabled;entries=$result.Entries.Count;calls=$type::DiagnosticLeafCalls;peak=$type::DiagnosticPeakLeaves;active=$type::DiagnosticActiveLeaves;scratch=$scratch}
[IO.File]::WriteAllText((Join-Path $PSScriptRoot "diagnostics-check-$Enabled.json"),($record|ConvertTo-Json))
Write-Output "诊断开关检查: enabled=$Enabled passed=$pass"
if(-not $pass){exit 1}
exit 0
