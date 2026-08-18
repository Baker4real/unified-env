# CLOSEABLE.md — GitHub #41 Journal 性能监控和告警

这不是 GitHub 关单授权。本文只记录实现关口是否可交给根 Agent 汇总。未 commit / comment / close #41。

## 关口结论

`BLOCKED`

监控、报告、慢 flush 警告和 10k 夹具都在。热路径 `ThreadJournalWriter.Flush()` 已恢复为每次 `FileStream.Flush(true)`（等价 FlushFileBuffers）。`#39` 每文件 `WriteEntry(pending)→Flush→File.Delete→WriteEntry(commit)→Flush` 未改成整树 pending 再一次 fsync。现役 `Invoke-CodexSafeTreeDeletePurge` 未接线。没有对生产 leftover 做 Purge/Restore/Archive。

**结构冲突：** 性能 spec 要求 pending/commit 在 delete 前 / 返回前 hit disk；`#39` 要求每文件两次 Flush。本机 10k 因此是 20000 次 `Flush(true)`。本轮 live：`TotalFlushTimeMs=9030` / `elapsedMs=60656` = **14.887%**，`IsWithinTarget=false`，`FlushCount=20000`，`SlowFlushCount=0`，`failedCount=0`。删除仍成功，没有因此失败闭锁。数字未伪造。未用 `Flush(false)` 或批量 pending 来假装 `<10%`。

根 Agent 已决定不关 GitHub #41。本关口保持 `BLOCKED`。

## 关口证据

- 测试：`tests/Test-CodexSafeTreeDeleteJournalPerformance.ps1`
- 运行器：`D:\Codex\tools\PowerShell\7.6.4\pwsh.exe`（Core 7.6.4）
- 退出码：JournalPerformance `0`；ParallelPurgeCoordinator `0`
- stdout：`Test-CodexSafeTreeDeleteJournalPerformance.stdout.txt`（`ok=True`，5 slices，`scaleIsWithinTarget=False`）
- stderr：空
- 字面公式示例：`journal-performance-report-example.json`（200ms / 2000ms = 10%，`IsWithinTarget=false`）
- 10k JSON：`scale-10000.json`、`journal-performance-report-10k.json`
- `git diff --check -- scripts/lib/CodexSafeTreeDeleteThreadJournal.cs tests/Test-CodexSafeTreeDeleteJournalPerformance.ps1`：`DIFFCHECK_EXIT=0`
- 10k 树已删；保留 journal 与报告。夹具只写本目录下 `fixtures-*`
- leftover 未碰：`reports/.codex-safe-delete-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e.quarantine` 与对应 `transaction.json` 仍在

## 逐条 AC

1. **通过。** `ThreadJournalWriter.TotalFlushTimeMs` 累积 `Flush()` 内 Stopwatch ticks，再换成毫秒。
2. **通过。** `FlushCount` 每次 `Flush()` +1。10k 为 20000。
3. **通过。** `Flush()` 用 `Stopwatch` 包住 `_streamWriter.Flush()` 与 `_fileStream.Flush(true)`。热路径没有 `Flush(false)`。
4. **通过。** 单次 >100ms 写入 `SlowFlushCount` / `LastSlowFlushWarning`。10k 现场 `SlowFlushCount=0`。
5. **通过。** `ParallelPurgeCoordinator.Purge` 在 Dispose writer 前汇总全部 `TotalFlushTimeMs`。
6. **通过。** `OverheadPercent = TotalFlushTimeMs / Purge.ElapsedMs * 100`。
7. **通过。** `JournalPerformanceReport`：`TotalFlushTimeMs`、`FlushCount`、`OverheadPercent`、`IsWithinTarget`。
8. **通过。** `IsWithinTarget = (OverheadPercent < 10)`。字面 `FromTotals(200, 4, 2000)` → 10% / false。
9. **通过。** ≥10% 时 `Warning` 建议降低并行度或检查磁盘。10k 删除仍 `failedCount=0`，未失败闭锁。
10. **通过。** 单元：20 次 `Flush` 后 `FlushCount=20`，`TotalFlushTimeMs` 单调非负。
11. **通过。** 单元：200/2000=10%、199/2000=9.95%、100/2000=5%。
12. **未达目标，已如实记录。** 10k 夹具 hit-disk overhead **14.887%**，不是 <10%。测试只断言公式与 `IsWithinTarget` 一致，不把 `<10%` 硬断言成绿。
13. **通过。** 示例与 10k 报告均已落盘。
14. **通过。** pending `Flush(true)` 后、delete 前第二句柄可读到 pending（本票 writer 切片 + `#39` coordinator）。这证明可见性，不单独证明断电；hit disk 由热路径 `Flush(true)` 承担。

## 两轴审查（相对进入本关口的工作树）

固定点：进入本关口时的工作树（不是独立 commit）。审查范围仅本票写入。未开并行子代理；两轴由本实现代理内联完成。

### Standards

- 无硬违反仓库编码标准。对本票源文件 `git diff --check` 通过。
- 未改 `FileIdentity.cs`、`CodexSafeTreeDelete.ps1`、`CodexHostSafety.ps1`、`CodexSafeTreeDeleteParallelPurge.cs`、`modules/manifest.json`、根/`host-safety` CONTEXT、性能 spec、policy、hooks。
- 2-arg `ThreadJournalWriter` / `ThreadJournalOwner` 仍默认 issue38 测试根。
- 未写生产 Windows Event Log。慢 flush 与 overhead 警告都在对象属性上可观察。
- `File.Delete` 只打在 issue41/issue39 夹具树；允许根为构造注入。
- 判断：小树 overhead 约 55% 不是验收场景（墙钟太短）；验收数字以 10k 为准。

### Spec

- 票面监控、公式、报告、警告、单元计数器与字面公式均有 live 证明。
- 热路径每次 journal Flush 都 `Flush(true)`，对齐性能 spec「Pending entry must hit disk before OS delete」「Commit entry must hit disk before function returns」。
- `#39` 每文件两次 Flush 未改成批量。未接生产 Purge。
- 10k 目标 `<10%` 在 hit-disk Flush 下未达到。按根 Agent 决定标 `BLOCKED`，未关 GitHub #41。

**Standards 0 硬违反 / 1 判断味道；Spec 1 条验收目标未达（10k overhead <10% 与每文件两次 Flush(true) 在本机冲突）。**

## 未解决问题

- 10k journal overhead 14.887% ≥ 10%。在不破坏 `#39` 每文件两次 hit-disk Flush 的前提下，本机达不到 `<10%`。
- 未接入生产 Purge（#42）。
- 未改 `modules/manifest.json`（根 Agent 登记）。
- 未碰 leftover `0ab1e1b6`。
- 未碰 #40 的 `FileIdentity.cs`。
- 未 commit / comment / close #41。
