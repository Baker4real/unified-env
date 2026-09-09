param([ValidateSet('legacy','pooled')][string]$Mode='legacy')
$ErrorActionPreference='Stop'
$env:CODEX_SAFE_TREE_DELETE_STATUS_SEGMENTS='1'
$env:CODEX_SAFE_TREE_DELETE_STATUS_DEBUG_OP_TIMING='1'
$env:CODEX_SAFE_TREE_DELETE_STATUS_POOLED_HASH_BUFFER=if($Mode -eq 'pooled'){'1'}else{'0'}
$setup=[Diagnostics.Stopwatch]::StartNew()
. (Join-Path $PSScriptRoot 'prepare-runtime.ps1')
Add-Type -Path (Join-Path $PSScriptRoot 'ProcessObservation.cs')
$setup.Stop();$self=[Diagnostics.Process]::GetCurrentProcess();$cpu=$self.TotalProcessorTime.TotalMilliseconds
$io=[Issue58N1.ProcessMetrics]::Io($self);$allocated=[GC]::GetTotalAllocatedBytes($false);$pause=[GC]::GetTotalPauseDuration().TotalMilliseconds
$collections=@(0..2|ForEach-Object{[GC]::CollectionCount($_)})
$watch=[Diagnostics.Stopwatch]::StartNew();$code=0
try { & (Join-Path $repo 'scripts/Invoke-CodexSafeTreeDelete.ps1') -Mode Status -Json; $code=if(Test-Path Variable:LASTEXITCODE){$LASTEXITCODE}else{0} }
finally {
    $watch.Stop();$self.Refresh();$afterIo=[Issue58N1.ProcessMetrics]::Io($self);$type=[CodexSafeTreeDelete.StatusTreeSnapshotScanner]
    $summary=@{mode=$Mode;statusElapsedMs=$watch.ElapsedMilliseconds;setupMs=$setup.ElapsedMilliseconds;entryExitCode=$code
        cpuMs=$self.TotalProcessorTime.TotalMilliseconds-$cpu;allocatedBytes=[GC]::GetTotalAllocatedBytes($false)-$allocated;gcPauseMs=[GC]::GetTotalPauseDuration().TotalMilliseconds-$pause
        gcCollections=@(0..2|ForEach-Object{[GC]::CollectionCount($_)-$collections[$_]});readBytes=$afterIo.ReadBytes-$io.ReadBytes;readOperations=$afterIo.ReadOperations-$io.ReadOperations
        writeBytes=$afterIo.WriteBytes-$io.WriteBytes;writeOperations=$afterIo.WriteOperations-$io.WriteOperations;peakWorkingSetBytes=$self.PeakWorkingSet64
        activeLeaves=$type::DiagnosticActiveLeaves;peakLeaves=$type::DiagnosticPeakLeaves;leafCalls=$type::DiagnosticLeafCalls;leafWorkMs=$type::DiagnosticLeafWorkMs
        scannerSourceSha256=(Get-FileHash -LiteralPath (Join-Path $repo 'scripts/lib/CodexSafeTreeDeleteStatusScan.cs')).Hash.ToLowerInvariant()
        pooledBuffer=$Mode -eq 'pooled';note='仅 buffer 租借策略变化；read/hash/identity 与 DOP/组/缓存保持不变。'}
    [IO.File]::WriteAllText((Join-Path $env:ISSUE58_RUN_ROOT 'diagnostic.json'),($summary|ConvertTo-Json -Depth 8))
}
exit $code
