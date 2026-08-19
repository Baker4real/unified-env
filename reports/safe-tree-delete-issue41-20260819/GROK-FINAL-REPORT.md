# GROK-FINAL-REPORT — GitHub Issue #41

状态：`DONE_WITH_CONCERNS`

仓库 `D:\Codex\projects\统一环境`，分支 `wip/2026-08-18-host-and-safe-delete`，HEAD `5f7f597`。未提交的 #32/#40 改动未回退。未 commit / push / 关 issue。

## 13 条 AC

| # | 条件 | 结果 | 证据 |
|---|---|---|---|
| 1 | `ThreadJournalWriter.TotalFlushTimeMs` 累积 flush 耗时 | **PASS** | `CodexSafeTreeDeleteThreadJournal.cs`；单元测试 20 次 Flush 单调累加 |
| 2 | `ThreadJournalWriter.FlushCount` | **PASS** | 同上；小树 group-commit FlushCount=6 |
| 3 | Flush 内 Stopwatch 测每次耗时 | **PASS** | `Flush()` 用 `Stopwatch.StartNew()` 包住 `StreamWriter.Flush` + `FileStream.Flush(true)` |
| 4 | 单次 flush >100ms 记慢 flush | **PASS** | `SlowFlushCount` / `LastSlowFlushWarning`；本次 10k `SlowFlushCount=0`（本机 SSD 未触发） |
| 5 | Coordinator 汇总所有线程 `TotalFlushTimeMs` | **PASS** | `ParallelPurgeCoordinator.Purge` `Interlocked.Add` 后 `FromTotals` |
| 6 | overhead% = TotalFlushTimeMs / TotalOperationTimeMs | **PASS** | `FromTotals` 字面 `200/2000=10`；10k 用 Purge 墙钟 |
| 7 | `JournalPerformanceReport` 类 | **PASS** | 字段齐全 |
| 8 | `IsWithinTarget = (OverheadPercent < 10%)` | **PASS** | 10% 为 false；9.95% 为 true |
| 9 | overhead ≥10% 警告并建议降并行/查磁盘 | **PASS** | 示例报告 warning 含 parallel + disk；优化后 DOP4 实测 13.4% 仍走警告、删除不失败闭锁 |
| 10 | 单元测试：计数器正确累积 | **PASS** | `Test-CodexSafeTreeDeleteJournalPerformance.ps1` slice 1 |
| 11 | 单元测试：overhead 公式正确 | **PASS** | slice 3 独立字面量 |
| 12 | 集成：10k+ journal overhead <10% | **PASS** | DOP=2 两组：7.875% / 6.229%，`IsWithinTarget=true` |
| 13 | 性能报告输出示例 | **PASS** | `journal-performance-report-example.json`（200/2000=10% 出界） |

## 优化前后 overhead（10k tiny × 4 目录）

口径：线程 flush 求和 / Purge 墙钟。默认 DOP=2（#40 峰值效率）。

| DOP | 优化前 FlushCount | 优化前 overhead% | 优化后 FlushCount | 优化后 overhead% | 优化后墙钟 ms |
|---:|---:|---:|---:|---:|---:|
| 1 | 20000 | 6.177 | 632 | **3.002** | 8595 |
| 2 | 20000 | **11.981** | 632 | **6.092**（集成 7.875 / 6.229） | 4301 |
| 4 | 20000 | 22.123 | 632 | 13.400 | 1888 |

历史对照：0817 报告 15.75%；#40 10k×1KB DOP2 25.796%（32 目录、更短墙钟、同一 ~7.3s flush 分子）。

优化：目录内 group-commit，B=32。每批：写 pending → **一次** `Flush(true)` → 第二句柄确认全部 pending → delete → 成功者写 commit → **一次** `Flush(true)`。未使用 `Flush(false)`，未改墙钟分母。

崩溃语义：pending 耐久之后才 delete；commit 只覆盖删除成功的文件；pending 已落盘且文件已不在、无 commit → uncertain。窗口从 1 个文件放大到最多 32 个。slice 2b 用 4 pending / 删 2 / 无 commit 证明 2 uncertain + 2 resumable。

## 改动清单

- `scripts/lib/CodexSafeTreeDeleteParallelPurge.cs`：`GroupCommitSize`（默认 32）、`PurgeFilesInGroups` / `PurgeBatch`
- `tests/Test-CodexSafeTreeDeleteJournalPerformance.ps1`：证据改到本目录；去掉每文件 2 次 Flush 断言；10k×2 断言 `<10%`；group-commit uncertain 切片
- `tests/Test-CodexSafeTreeDeleteParallelPurgeCoordinator.ps1`：journal 行序改为「commit 之前必须有同一 path 的 pending」（保留 #40 DOP=2 断言）

未改：#32/#40 源码与测试、生产 `Invoke-CodexSafeTreeDeletePurge`。

## 绿清单

| 测试 | 结果 |
|---|---|
| ThreadJournal | PASS (733ms) |
| JournalPerformance | PASS（含 10k×2） |
| ParallelPurgeCoordinator | PASS（含 10k） |
| ParallelismBenchmark `-SkipBenchmark` | PASS |
| CrashSafety | PASS（13 scenarios；曾因 stale `CodexHostSafetyNative.dll` 无法覆盖而失败，删除该编译缓存后重跑） |
| UncertainRecovery | PASS |
| FileSystem | 未跑（#35 waiver 红除外） |

`git diff --check` 对本票改动退出码 0。

## 证据目录

`reports/safe-tree-delete-issue41-20260819/`

- `DIAGNOSIS.md`、`flush-profile.json`（优化前）、`flush-profile-after.json`
- `journal-performance-report-example.json`
- `journal-performance-report-10k.json` / `-s1.json` / `-s2.json` / `scale-10000.json`
- `git-restore-log.json`
- 夹具 journal：`fixtures-*/scale-10000-journal-s*`、`work/`、`work-after/`

## git restore

`git checkout --` 恢复测试改写的 tracked 快照：

- `reports/safe-tree-delete-issue34-20260817/integration-results.json`
- `reports/safe-tree-delete-issue39-20260817/scale-10000.json`

## 风险与未决

1. **DOP4 仍 13.4%**：分子是线程求和，墙钟随并行下降，>2 的 DOP 仍可能 ≥10%。警告路径按合同工作。关闭条件按 #40 推荐 DOP=2 验收。
2. **uncertain 窗口 ≤32 文件**：崩溃发生在一批 delete 之后、commit flush 之前时，uncertain 集合比每文件 flush 更大。判据未放宽。
3. **`ParallelPurgeCoordinator` 仍只接夹具**，不是生产 HostSafety Purge。
4. 未关 GitHub issue、未 commit。

## 勘误（发布前，2026-08-19）

初稿 AC12 行与优化表 DOP2 行曾误记 10k 集成开销为 6.166% / 6.397%。以同目录机器证据为准：`journal-performance-report-10k-s1.json` OverheadPercent = 7.874762808349146，`journal-performance-report-10k-s2.json` OverheadPercent = 6.228874939642685（正文按三位小数记 7.875% / 6.229%）。两组 `IsWithinTarget=true` 不变，AC12「<10%」结论不变。
