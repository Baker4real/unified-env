# CLOSEABLE.md — GitHub #38 ThreadJournalWriter 和生命周期管理

这不是 GitHub 关单授权。本文只记录实现关口是否可交给根 Agent 汇总。未 commit / comment / close #38。

## 关口结论

`DONE`

本票只建类型、ThreadLocal 生命周期和单元测试。现役删除仍是 `Remove-CodexHookCapabilityDirectoryTree` 的目录 freeze/commit journal。没有把并行 Purge 接到热路径，没有改 HostSafety 删除循环，没有对生产 leftover 做 Purge/Restore/Archive。

## 关口证据

- 测试：`tests/Test-CodexSafeTreeDeleteThreadJournal.ps1`
- 运行器：`D:\Codex\tools\PowerShell\7.6.4\pwsh.exe`（Core 7.6.4）
- 退出码：`0`（`suite-meta.json`）
- stdout：`Test-CodexSafeTreeDeleteThreadJournal.stdout.txt`（`ok=True`，6 slices）
- stderr：空
- `git diff --check`：对本票文件通过（`DIFFCHECK_EXIT=0`）
- 夹具只写本目录下 `fixtures-*`，create-only，未覆盖已有 journal

## 逐条 AC

1. **通过。** `ThreadJournalWriter` 在 `scripts/lib/CodexSafeTreeDeleteThreadJournal.cs` L9，封装 `FileStream` + `StreamWriter`。
2. **通过。** 构造函数 L18 接受 `journalFilePath` 与 `threadId`。
3. **通过。** `WriteEntry` L47 写一行 JSON（LF 结尾）；测试用字面值 `{"op":"pending","path":"leaf.txt"}` / `{"op":"commit","path":"leaf.txt"}`。
4. **通过。** `Flush` L69 先刷 `StreamWriter`，再 `_fileStream.Flush(true)`（L73）。另一句柄能读到完整条目。
5. **通过。** `IDisposable`：writer L76，owner L258。
6. **通过。** `new ThreadLocal<ThreadJournalWriter>(CreateWriterForCurrentThread, true)`（L176–178，`trackAllValues: true`）。
7. **通过。** `GetOrCreateThreadJournal` L200 返回当前线程 writer；同线程二次调用同一实例。
8. **通过。** `ThreadJournalOwner.Dispose` L268 枚举 `_threadJournals.Values` 并对每个 writer `Dispose`；单线程抛错与工作线程抛错都走 `finally`。
9. **通过。** 4 个工作线程，各自独立 writer / threadId / 文件。
10. **通过。** `owner.Values` 含 4 个 writer。
11. **通过。** 工作抛 `work-failed` 后 `finally` 仍 Dispose，句柄可 `FileShare.None` 打开。
12. **通过。** Dispose 前 `FileShare.None` 被挡；Dispose 后独占打开成功。

额外证明（票面实现约束，不是 GitHub AC 原文）：跨目录两个 owner 是不同实例、不同文件；同一路径第二次 `CreateNew` 失败。

## 两轴审查（相对进入本关口的工作树）

固定点：进入本关口时的工作树（不是独立 commit）。审查范围仅本票写入。未开并行子代理；两轴由本实现代理内联完成。

### Standards

- 无硬违反仓库编码标准。`git diff --check` 对本票文件通过。
- 未改 `managed/safe-tree-delete/policy.json`、hooks、`managed/grok-hooks/`、ProductionSmoke、HostSafety 删除循环、Purge 热路径。`CodexSafeTreeDelete.ps1` 只多编一个 `.cs`。
- 判断：`GetOrCreateOnNewThreads` 是测试用来在真实 OS 线程上调用工厂的小组件，不是无人消费空壳；#39 应继续走 `GetOrCreateThreadJournal`，不必依赖该方法。
- 判断：journal 根写死为 `reports/safe-tree-delete-issue38-20260817/`，避免本票类型被误接到生产 journal。#39 接线前必须改允许根。
- 判断：`Validate-ModuleBoundaries.cjs` 全仓仍红，原因是进入本关口前已有的无主 reports / 缺失 prefix；本票文件已登记，错误列表里没有 issue38 路径。

### Spec

- 票面 12 条 AC 均有 live 单元证明。
- 性能 spec「每目录一个 fresh writer、禁止跨目录复用」用双 owner 证明。
- 没有把 `Parallel.ForEach` 引入 `Invoke-CodexSafeTreeDeletePurge`。没有替换现役 HostSafety freeze/commit。
- 没有假装本 journal 是生产 `directory-delete-*-freeze.json`。崩溃安全的「pending 先于 delete」仍由未来调用方保证；本票只证明 Flush 后另一句柄可读完整条目。
- `Flush(true)` 的掉电耐久无法用本机单元测试证明，只能证明调用了 `FileStream.Flush(true)` 且第二句柄可见。

**Standards 0 硬违反 / 2 判断味道；Spec 0 缺失要求。**

## 未解决问题

- 未接入 Purge / `ParallelPurgeCoordinator`（#39+）。
- 允许根仍是本票测试目录；生产 journal 路径会被构造函数拒绝。
- 未重跑 CrashSafety / Uncertain / LeafStreamSet / HashReuse（本票未改那些路径）。
- 未 commit / comment / close #38。
- 全仓 `Validate-ModuleBoundaries.cjs` 仍因他人 WIP / 历史 reports 失败，不是本票回归。
