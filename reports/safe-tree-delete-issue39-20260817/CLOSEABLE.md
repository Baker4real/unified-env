# CLOSEABLE.md — GitHub #39 ParallelPurgeCoordinator 目录级并行

这不是 GitHub 关单授权。本文只记录实现关口是否可交给根 Agent 汇总。未 commit / comment / close #39。

## 关口结论

`DONE_WITH_CONCERNS`

本票落地可测的 `ParallelPurgeCoordinator`（真类型、真 `Parallel.ForEach`、真 journal）。`File.Delete` 只打在 issue39 夹具树。现役 `Invoke-CodexSafeTreeDeletePurge` 仍走 `Remove-CodexHookCapabilityDirectoryTree`。没有对生产 leftover 做 Purge/Restore/Archive。

## 关口证据

- 测试：`tests/Test-CodexSafeTreeDeleteParallelPurgeCoordinator.ps1`
- 运行器：`D:\Codex\tools\PowerShell\7.6.4\pwsh.exe`（Core 7.6.4）
- 退出码：`0`（`suite-meta.json`）
- stdout：`Test-CodexSafeTreeDeleteParallelPurgeCoordinator.stdout.txt`（`ok=True`，5 slices；10k `fileCount=10000` / `elapsedMs=31339` / `journalFileCount=4` / `failedCount=0`）
- stderr：空
- 10k JSON：`scale-10000.json`
- `git diff --check`：对本票文件通过（`DIFFCHECK_EXIT=0`）
- 10k 树已删；保留 journal 与报告。夹具只写本目录下 `fixtures-*`

## 逐条 AC

1. **通过。** `ParallelPurgeCoordinator` 在 `scripts/lib/CodexSafeTreeDeleteParallelPurge.cs` L50。
2. **通过。** `GroupByTopLevelDirectory` L128：按顶级子目录分组；根下散文件归 `root`。
3. **通过。** `Parallel.ForEach` L223 处理各组。
4. **通过。** `ResolveMaxDegreeOfParallelism` L107：`RecommendParallel=true` 时读 `RecommendedMaxParallelism`（optimize=4）；`false` 时强制 DOP=1。实例属性 `MaxDegreeOfParallelism` L101。
5. **通过。** 每组一个 `ThreadJournalOwner`，组内 `GetOrCreateThreadJournal` L232。未调用 `GetOrCreateOnNewThreads`。
6. **通过。** 每文件：`WriteEntry(pending)` → `Flush` → 第二句柄读到 pending（`VerifyPendingVisible`）→ 确认文件仍在 → `File.Delete` L324 → `WriteEntry(commit)` → `Flush`。`FilesPresentAfterPending` 计数与失败路径（pending 已写、无 commit、文件仍在）共同证明 pending 先于 delete 落盘。
7. **通过。** 单文件 `catch` 后继续；`FailedCount` / `Errors` 汇总；不假装全成功。
8. **通过。** 组内 `finally` Dispose owner；`Purge` 外层 `finally` 与 `IDisposable` 再清 `ConcurrentBag` 中全部 owner。
9. **通过。** 4 个顶级目录、6 个文件全部删除。
10. **通过。** 每顶级目录独立 `{key}.thread-{tid}.jsonl`。
11. **通过。** journal 字面行序 `pending` 紧接同路径 `commit`。
12. **通过。** `FileShare.None` 锁住一个文件：该文件不删、不 commit；另外两个文件删除并 commit。
13. **通过。** 10k×小文件（4×2500）：`fileCount=10000`，`elapsedMs=31339`，`journalFileCount=4`，`failedCount=0`。pending/commit 各 10000 行。

## 两轴审查（相对进入本关口的工作树）

固定点：进入本关口时的工作树（不是独立 commit）。审查范围仅本票写入。未开并行子代理；两轴由本实现代理内联完成。

### Standards

- 无硬违反仓库编码标准。`git diff --check` 对本票文件通过。
- 未改 `managed/safe-tree-delete/policy.json`、hooks、ProductionSmoke、HostSafety 删除循环、Purge 热路径。`CodexSafeTreeDelete.ps1` 只多编一个 `.cs`（该文件工作树里还有他人已有 WIP，本票未动那些 hunk）。
- 判断：3-arg 构造注入允许根；2-arg 仍默认 `LegacyAllowedJournalRootForTests`（issue38 路径），只为不改 #38 测试。新调用方必须传入允许根。
- 判断：`AfterPendingFlushed` 是可选钩子。并行测试不用 PowerShell 回调（worker 线程没有 runspace）。AC6 由 C# 第二句柄校验证明。
- 判断：`Validate-ModuleBoundaries.cjs` 全仓仍可能因他人 WIP / 历史 reports 失败；本票文件已登记。

### Spec

- 票面 13 条 AC 均有 live 证明。
- `File.Delete` 只打在 `reports/safe-tree-delete-issue39-20260817/` 夹具树；目标与 journal 都必须落在注入允许根下。
- 没有把 `Parallel.ForEach` / `File.Delete` 引入 `Invoke-CodexSafeTreeDeletePurge`。接线属 #42。
- 只并行顶级子目录；目录内文件串行。
- `RecommendParallel=false` 时 DOP=1，串行夹具也删干净。

**Standards 0 硬违反 / 2 判断味道；Spec 0 缺失要求。**

## 未解决问题

- 未接入生产 Purge（#42）。
- 2-arg `ThreadJournalWriter` / `ThreadJournalOwner` 仍默认 issue38 测试根；未重跑 #38 测试（2-arg 签名未破）。
- 根 `CONTEXT.md` 与性能 spec 仍写「ParallelPurgeCoordinator 仍属 #39」（本票独占范围只改 `modules/host-safety/CONTEXT.md` 一句）。
- 未重跑 CrashSafety / Uncertain / LeafStreamSet / HashReuse（本票未改那些路径）。
- 未做 #40 线程数调参、#41、#49 Status。
- 未 commit / comment / close #39。
