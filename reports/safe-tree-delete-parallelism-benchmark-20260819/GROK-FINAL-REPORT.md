# GROK-FINAL-REPORT：GitHub #40 并行度基准与推荐逻辑

状态：`DONE`

仓库：`D:\Codex\projects\统一环境`  
分支：`wip/2026-08-18-host-and-safe-delete`  
测量：2026-08-18T21:05:28Z–21:13:27Z（墙钟约 480s）  
证据：`reports/safe-tree-delete-parallelism-benchmark-20260819/`

## 结论

本机三个夹具场景的峰值并行效率都在 **DOP 2**。票面「小文件 4 / `min(4, ProcessorCount-2)`」不被当前数据支持。`FileSystemCapabilities.RecommendedMaxParallelism` 已改为场景分级、由本次测量支撑：小/中/大均为 2；未知规模的 `FromDetection` 也取 2。网络/FAT32 安全边界未放宽。

墙钟仍随 DOP 升到 16 而下降，1..16 没有 <10% 增量平台。生产默认取效率峰值而不是墙钟最小，避免 journal flush 线程求和随 DOP 线性膨胀。

## 13 条 AC

| # | 关闭条件 | 结果 | 证据 |
| ---: | --- | --- | --- |
| 1 | 并行度基准测试套件存在 | 通过 | `tests/Test-CodexSafeTreeDeleteParallelismBenchmark.ps1` |
| 2 | 场景 1：10k×1KB | 通过 | `raw/small-10k-1kb-dop*.json`，2 次取样 |
| 3 | 场景 2：5k×10KB | 通过 | `raw/medium-5k-10kb-dop*.json`，2 次取样 |
| 4 | 场景 3：1k×1MB | 通过 | `raw/large-1k-1mb-dop*.json`，2 次取样 |
| 5 | 每场景测 DOP 1/2/4/8/16 | 通过 | 15 组聚合 + 30 条 raw 取样 |
| 6 | 测总耗时（wall-clock） | 通过 | 每条 raw 的 `wallClockMs` |
| 7 | 测 CPU 利用率（Process.TotalProcessorTime） | 通过 | `totalProcessorTimeMs` / `cpuUtilizationRatio` |
| 8 | 测 journal flush 总耗时与开销百分比 | 通过 | `flushTimeMs` / `flushOverheadPercent`，`flushStatus=measured` |
| 9 | 性能曲线（线程数 vs 耗时） | 通过 | `curve.json`、`REPORT.md` mermaid |
| 10 | 收益递减点分析 | 通过 | `analysis.json`：1→16 无 <10% 墙钟台阶；效率在峰值 2 之后下降 |
| 11 | 小/中/大各自最优 DOP | 通过 | 峰值效率均为 2；墙钟最佳均为 16 |
| 12 | 更新 `RecommendedMaxParallelism` 逻辑 | 通过 | `FileSystemCapabilities` 场景分级 2/2/2；`FromDetection` optimize=2；coordinator/Phase3 断言已对齐 |
| 13 | 性能报告与各场景建议 | 通过 | `REPORT.md`、`analysis.json`、本文 |

## 三场景最优 DOP

决策规则：并行效率 = (DOP1 墙钟 / 该 DOP 墙钟) / DOP。

| 场景 | 推荐 DOP（效率峰值） | 效率 | 墙钟最佳 | 说明 |
| --- | ---: | ---: | ---: | --- |
| 小 10k×1KB | **2** | 1.060 | 16 / 5264ms | 票面 4 不被支持 |
| 中 5k×10KB | **2** | 1.002 | 16 / 2296ms | DOP4 效率 0.922，已低于峰值 |
| 大 1k×1MB | **2** | 1.811 | 16 / 328ms | 票面 1–2 区间内；见下方方差 |

均值墙钟（两次取样）：

| 场景 | 1 | 2 | 4 | 8 | 16 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 小 | 60451 | 28508 | 14907 | 8812 | 5264 |
| 中 | 24923 | 12443 | 6760 | 4020 | 2296 |
| 大 | 5722 | 1580 | 885 | 514 | 328 |

大文件 DOP1 两次为 8426 / 3018ms，未丢弃。若只用第二次，大文件效率峰值会偏向 1；本轮按预先口径取平均，推荐仍为 2。

## 推荐逻辑改动

文件：`scripts/lib/CodexSafeTreeDeleteFileIdentity.cs`

- 删除固定 detection 值 4。
- `RecommendMaxParallelismForTypicalFileBytes(bytes)`：
  - `>= 1MiB` → 2（大）
  - `>= 10KiB` → 2（中）
  - 其余 → 2（小）
- `RecommendOptimizeMaxParallelism()` = 典型小文件路径，返回 2。
- `FromDetection` 可优化时用上述默认；网络/FAT32/exFAT/`RecommendParallel=false` 仍为 1。

测试对齐：`Test-CodexSafeTreeDeleteFileSystem.ps1`、`Test-CodexSafeTreeDeleteParallelPurgeCoordinator.ps1`、`Test-CodexSafeTreeDeletePhase3Integration.ps1` 仅把本地 NTFS/ReFS optimize 期望从 4 改为 2，未放宽 #35 安全判据。

## 验收修复轮（断言对齐）

过期「推荐值=4」断言已改为本机峰值效率 2。夹具自选 DOP 与历史 `#40` DOP4 raw 格子未改。

| 文件 | 行 | 原断言 | 现断言 |
| --- | ---: | --- | --- |
| `Test-CodexSafeTreeDeleteParallelPurgeCoordinator.ps1` | 124 | `RecommendedMaxParallelism -eq 4` | `-eq 2` |
| 同上 | 130 | `optimizeDop -eq 4`（AC4） | `-eq 2` |
| 同上 | 171 | `coordinator.MaxDegreeOfParallelism -eq 4` | `-eq 2` |
| `Test-CodexSafeTreeDeletePhase3Integration.ps1` | 611 | `coordinator.MaxDegreeOfParallelism -eq 4` | `-eq 2` |

保留未改：

- ParallelPurgeCoordinator 126 / 273：FAT32 / `RecommendParallel=false` 仍为 1
- Phase3 392 / 395：网络卷仍为 1
- Phase3 49 / 725–734 / 936 / 1007–1011 / 1032 / 1073：读历史 `#40` `small-10k-1kb-dop04.json` 的 **取样格子 degree=4**，不是推荐值

复跑：ParallelPurgeCoordinator 绿（70s）；Phase3Integration 绿（908s）；ParallelismBenchmark `-SkipBenchmark` 绿（1s）。跑脏的 `#39`/`#42` tracked 快照已 `git checkout --` 恢复。

## 验证

| 项 | 结果 |
| --- | --- |
| ParallelismBenchmark 全量 3×5×2 | 先红（当时 FromDetection=4），改逻辑后 `-SkipBenchmark` 绿 |
| ThreadJournal | 绿 |
| JournalPerformance | 绿（10k overhead 11.82%，目标 <10% 仍未达） |
| FileSystem 推荐/安全切片 | 绿 |
| FileSystem #35 实卷 VHD | 红，`diskpart` 需要提升；属既有 waiver，未改判据 |
| ParallelPurgeCoordinator | 绿（断言已对齐 DOP 2） |
| Phase3Integration | 绿（optimize coordinator DOP 已对齐 2） |
| 历史证据哈希 | 未改写 `parallelism-benchmark/` 与 `#40` 历史目录；本轮 `#39`/`#42` 跑脏后已还原 |
| `git diff --check` | 通过 |

## 风险与未决

1. **#35 实卷未提权。** FileSystem 实卷 VHD 因 elevation 失败，与本次推荐改动无关。
2. **生产 Purge 仍未接 `ParallelPurgeCoordinator`。** 本次数字只描述夹具 `File.Delete`，不能当成生产删除加速。
3. **journal overhead 随 DOP 上升。** 小文件 DOP2 已约 26%，DOP16 约 168%（线程求和）。这是把默认留在效率峰值 2、而不是墙钟 16 的原因之一。
4. **大文件 DOP1 冷启动方差大。** 见上；未选择性取样。
5. **`RecommendMaxParallelismForTypicalFileBytes` 仍未接入生产 Purge。** 生产路径继续只看 `DeletionAllowed`。

## 回滚

还原 `scripts/lib/CodexSafeTreeDeleteFileIdentity.cs` 与两份测试即可回到固定 4。新证据目录是新增快照，不覆盖历史 tracked 文件。未 commit / push / 关单。

JournalPerformance 验证曾改写 `reports/safe-tree-delete-issue41-20260817/` 两份 tracked JSON，已用 `git checkout --` 恢复。同目录本次残留夹具 `fixtures-5064f0351a9644ca9789f89479dd97dc` 已走受管 Plan/Apply/Purge 删除（run `20260818T212016Z-cf5a1ffb-23f1-4241-a578-3eae37c7b887`）。预存在的 `fixtures-7b180093...` 未动。
