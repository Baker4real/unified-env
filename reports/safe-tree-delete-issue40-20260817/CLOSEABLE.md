# CLOSEABLE.md — GitHub #40 并行度基准测试和调优

这不是 GitHub 关单授权。本文只记录实现关口是否可交给根 Agent 汇总。未 commit / comment / close #40。

## 关口结论

`DONE_WITH_CONCERNS`

在 `ParallelPurgeCoordinator` 夹具树上完成 3 场景 × DOP 1/2/4/8/16 基准。用实测并行效率峰值决定推荐：小/中=4，大=2。`FromDetection` optimize 仍为 4。`File.Delete` 只打 issue40 夹具树。没有碰生产 leftover。

## 关口证据

- 测试：`tests/Test-CodexSafeTreeDeleteParallelismBenchmark.ps1`
- 运行器：`D:\Codex\tools\PowerShell\7.6.4\pwsh.exe`（Core 7.6.4）
- 测量跑：15 条 raw JSON 已写出（`raw/*-dopXX.json`）；首次全量跑在 mermaid `Measure-Object` 处失败，之后已修
- 验证跑：`-SkipBenchmark` 退出码 `0`（`suite-meta.json`）
- stdout：`Test-CodexSafeTreeDeleteParallelismBenchmark.stdout.txt`（`ok=True`，`smallPeak=4` / `mediumPeak=4` / `largePeak=2`，`flushVerified=True`）
- 报告：`REPORT.md`（Markdown 表 + mermaid 折线）
- 分析：`analysis.json`
- 预检：`preflight.json`（ProcessorCount=20，D: 约 389 GiB，足够 1k×1MB）
- `git diff --check`：对本票文件通过（`DIFFCHECK_EXIT=0`）
- payload 大树已删；保留 JSON/报告与 work 下 journal

## 逐条 AC

1. **通过。** 基准套件 `tests/Test-CodexSafeTreeDeleteParallelismBenchmark.ps1`。
2. **通过。** 场景 1：10k×1KB，32 顶级目录。
3. **通过。** 场景 2：5k×10KB。
4. **通过。** 场景 3：1k×1MB。
5. **通过。** 每场景 DOP 1/2/4/8/16，共 15 份 raw JSON。
6. **通过。** `wallClockMs` + `coordinatorElapsedMs`。
7. **通过。** `Process.TotalProcessorTime` → `totalProcessorTimeMs` / `cpuUtilizationRatio`。
8. **通过。** 读 `#41` 已接线的 `ParallelPurgeResult.JournalPerformance.TotalFlushTimeMs` / `OverheadPercent`；未改 ThreadJournal.cs。
9. **通过。** `REPORT.md` 表 + mermaid `xychart-beta` 折线。
10. **通过。** 增量墙钟 1→16 均 ≥10%，无平台；并行效率峰值小=4 / 中=4 / 大=2。
11. **通过（有关切）。** 生产默认取效率峰值而不是墙钟最佳 16。小文件 4 有数据（10k×1KB 4.48x / efficiency 1.12）。
12. **通过。** `RecommendOptimizeMaxParallelism()` = 4；`RecommendMaxParallelismForTypicalFileBytes`：1KB/10KB→4，1MB→2；`FromDetection` optimize 走前者。
13. **通过。** `REPORT.md` + `analysis.json` 含分场景建议。

## 两轴审查（相对进入本关口的工作树）

固定点：进入本关口时的工作树（不是独立 commit）。审查范围仅本票写入。未开并行子代理；两轴由本实现代理内联完成。

### Standards

- 无硬违反仓库编码标准。`git diff --check` 对本票文件通过。
- 未改 ThreadJournal / ParallelPurge / CodexSafeTreeDelete.ps1 / HostSafety / manifest / CONTEXT / 性能 spec / policy / hooks。
- 夹具只写 `reports/safe-tree-delete-issue40-20260817/`；`allowedRoot` 构造注入。DOP 用 capabilities 注入，未改 coordinator。
- 判断：`FileIdentity.cs` 相对 HEAD 的大 diff 含工作树里已有的 `FileSystemCapabilities`（他人 WIP）。本票只加了两个 Recommend* 方法，并把 `FromDetection` 的 magic 4 改为调用。未回退他人 WIP。
- 判断：`RecommendMaxParallelismForTypicalFileBytes` 供有文件规模的调用方使用；`FromDetection` 不知道规模，仍走典型小文件 4。

### Spec

- 票面 13 条 AC 均有 live 证据。先测量再改推荐，没有先写死票面数字。
- 墙钟最佳全是 16；生产默认取效率峰值 4/4/2，与票面「小 4 / 中 2-4 / 大 1-2」相容。
- flush 已测；`TotalFlushTimeMs` 是线程求和，DOP>1 时可超 100%。spec 的 <10% 目标在 DOP 4 小文件上为 47.9%（线程和）。
- 未接入生产 Purge（#42）。

**Standards 0 硬违反 / 2 判断味道；Spec 0 缺失要求 / 2 关切（墙钟无平台、flush 线程和定义）。**

## 未解决问题

- 1..16 墙钟未出现 <10% 增量台阶；若追最低墙钟应取 16。
- flush 开销按线程求和计，与 spec 「<10% 墙钟」不可直接比。
- `RecommendMaxParallelismForTypicalFileBytes` 未接入生产 Purge（#42）。
- 未重跑 FileSystem / ParallelPurgeCoordinator 套件（`FromDetection` 仍返 4）。
- `modules/manifest.json` 未登记新测试（根 Agent）。
- 未 commit / comment / close #40。
