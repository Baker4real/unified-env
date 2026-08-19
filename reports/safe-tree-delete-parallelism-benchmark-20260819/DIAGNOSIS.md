# #40 并行度基准诊断（2026-08-19）

## 测量对象

夹具只打 `ParallelPurgeCoordinator`（目录级 `Parallel.ForEach` + 每文件 pending→flush→`File.Delete`→commit）。不是生产 `Invoke-CodexSafeTreeDeletePurge`。#32 identity-first walker 不在这条夹具热路径上；本轮仍按当前工作树实现重测。

证据目录：`reports/safe-tree-delete-parallelism-benchmark-20260819/`。未改写 `reports/safe-tree-delete-parallelism-benchmark/` 与 `reports/safe-tree-delete-issue40-20260817/`。

## 口径

- 三场景：10k×1KB、5k×10KB、1k×1MB；每场景 DOP 1/2/4/8/16。
- 每组 2 次取样，全部落盘（`raw/*-s1.json` / `*-s2.json`），无未记录预热、无丢弃。
- 曲线与推荐用两次墙钟的算术平均。
- CPU：`Process.TotalProcessorTime` 差 / 墙钟。
- journal：`ParallelPurgeResult.JournalPerformance`（线程 flush 时间求和，DOP>1 时可超过墙钟 100%）。
- 推荐规则：各场景并行效率（speedup/DOP）峰值。墙钟 10% 膝点单独报告，不作为生产默认。

## 本机结果（ProcessorCount=20）

| 场景 | 峰值效率 DOP | 效率 | 墙钟最佳 | 10%膝点 | 1→16 是否出现 <10% 增量台阶 |
| --- | ---: | ---: | ---: | ---: | --- |
| 10k×1KB | 2 | 1.060 | 16 / 5264ms | 16 | 否 |
| 5k×10KB | 2 | 1.002 | 16 / 2296ms | 16 | 否 |
| 1k×1MB | 2 | 1.811 | 16 / 328ms | 16 | 否 |

票面假设（小 4、中 2–4、大 1–2、`min(4, ProcessorCount-2)=4`）不被本机峰值效率支持：`dataSupportsTicketSuggestion=false`。

## 取样方差

大文件 DOP1 两次墙钟 8426ms / 3018ms，均值 5722ms。第一次更像冷缓存，第二次接近后续 DOP 的量级。两笔都保留。若只用第二次 DOP1，大文件峰值效率会偏向 DOP1；本轮预先承诺「全部取样算术平均」，因此大文件推荐仍是 2。小/中 DOP1 相对差约 11% / 4%，其余格子两次接近。

## 推荐逻辑改动

`FileSystemCapabilities.FromDetection` 在可优化的本地 NTFS/ReFS 上不再返回固定 4。

- `RecommendMaxParallelismForTypicalFileBytes`：小（<10KiB）/ 中（<1MiB）/ 大（≥1MiB）分别对应本轮峰值 2 / 2 / 2。
- `RecommendOptimizeMaxParallelism` / 未知规模 `FromDetection`：取典型小文件峰值 2，不取墙钟 16。
- #35 安全边界未放宽：网络/FAT32/exFAT 仍 `RecommendParallel=false`、`RecommendedMaxParallelism=1`。

## 既有测试

| 测试 | 结果 | 说明 |
| --- | --- | --- |
| ParallelismBenchmark | 绿（`-SkipBenchmark`） | 新目录、30 条取样、推荐与峰值对齐 |
| ThreadJournal | 绿 | 未改 journal 源 |
| JournalPerformance | 绿 | 10k flush overhead 11.82%，仍超 10% 目标 |
| FileSystem 推荐/安全断言 | 绿 | NTFS/ReFS 期望从 4 改为 2；网络/FAT32 仍为 1 |
| FileSystem #35 实卷 VHD | 红（waiver） | `diskpart` 需要提升，未提权，未改红判据 |
| ParallelPurgeCoordinator | 红 | 只读测试仍钉 `RecommendedMaxParallelism=4` |

`Test-CodexSafeTreeDeletePhase3Integration.ps1` 同样钉 coordinator DOP=4，本票只读，未跑。
