$ErrorActionPreference='Stop'
$env:CODEX_SAFE_TREE_DELETE_STATUS_SEGMENTS='1'
$env:CODEX_SAFE_TREE_DELETE_STATUS_DEBUG_OP_TIMING='1'
$setup=[Diagnostics.Stopwatch]::StartNew()
. (Join-Path $PSScriptRoot 'prepare-runtime.ps1')
Add-Type -Path (Join-Path $PSScriptRoot 'ProcessObservation.cs')
$setup.Stop()
$self=[Diagnostics.Process]::GetCurrentProcess()
$cpu=$self.TotalProcessorTime.TotalMilliseconds
$io=[Issue58N1.ProcessMetrics]::Io($self)
$allocated=[GC]::GetTotalAllocatedBytes($false)
$pause=[GC]::GetTotalPauseDuration().TotalMilliseconds
$collections=@(0..2|ForEach-Object{[GC]::CollectionCount($_)})
$watch=[Diagnostics.Stopwatch]::StartNew()
$code=$null
try {
    & (Join-Path $repo 'scripts/Invoke-CodexSafeTreeDelete.ps1') -Mode Status -Json
    $code=if(Test-Path Variable:LASTEXITCODE){$LASTEXITCODE}else{0}
} finally {
    $watch.Stop();$self.Refresh()
    $afterIo=[Issue58N1.ProcessMetrics]::Io($self)
    $type=[CodexSafeTreeDelete.StatusTreeSnapshotScanner]
    $summary=@{
        statusElapsedMs=$watch.ElapsedMilliseconds;setupMs=$setup.ElapsedMilliseconds;entryExitCode=$code
        cpuMs=$self.TotalProcessorTime.TotalMilliseconds-$cpu;allocatedBytes=[GC]::GetTotalAllocatedBytes($false)-$allocated
        gcPauseMs=[GC]::GetTotalPauseDuration().TotalMilliseconds-$pause
        gcCollections=@(0..2|ForEach-Object{[GC]::CollectionCount($_)-$collections[$_]})
        readBytes=$afterIo.ReadBytes-$io.ReadBytes;readOperations=$afterIo.ReadOperations-$io.ReadOperations
        writeBytes=$afterIo.WriteBytes-$io.WriteBytes;writeOperations=$afterIo.WriteOperations-$io.WriteOperations
        peakWorkingSetBytes=$self.PeakWorkingSet64;observedThreadCountAtEnd=$self.Threads.Count
        activeLeaves=$type::DiagnosticActiveLeaves;peakLeaves=$type::DiagnosticPeakLeaves;leafCalls=$type::DiagnosticLeafCalls;leafWorkMs=$type::DiagnosticLeafWorkMs
        logicalProcessors=[Environment]::ProcessorCount;innerDop=[Math]::Min(32,[Math]::Max(4,[Environment]::ProcessorCount*2))
        note='leafWorkMs 为并行累计工作量，不是墙钟；进程 IO 包含 stdout，不代表 evidence 写入。'
    }
    [IO.File]::WriteAllText((Join-Path $env:ISSUE58_RUN_ROOT 'diagnostic.json'),($summary|ConvertTo-Json -Depth 6))
}
exit $code
