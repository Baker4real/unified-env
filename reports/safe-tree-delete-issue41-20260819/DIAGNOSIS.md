# #41 Journal flush 诊断（2026-08-19）

## 问题

监控/计数骨架已齐。未达的关闭条件是 **10k+ 集成：journal overhead < 10%**。

口径（现役、不可改）：

- `TotalFlushTimeMs` = 各线程 `ThreadJournalWriter` 内 `Flush()` 的 Stopwatch **求和**
- `TotalOperationTimeMs` = `ParallelPurgeCoordinator.Purge()` 墙钟
- `overhead% = TotalFlushTimeMs / TotalOperationTimeMs`
- DOP>1 时分子可超过墙钟（线程重叠）

## 当前触发粒度

`PurgeOneFile` 对每个文件：

1. `WriteEntry(pending)` → `Flush()` → `FileStream.Flush(true)`（`FlushFileBuffers`）
2. 第二句柄 `ReadToEnd` 证明 pending 可见（**不计入** `TotalFlushTimeMs`）
3. `File.Delete`
4. `WriteEntry(commit)` → 再一次 `Flush(true)`

10k 文件 = **20000 次** durable flush。`Flush(false)` / 推迟 pending 落盘已被 2026-08-18 审核否决。

## 现场 profile（本工作树，优化前）

证据：`flush-profile.json`。微基准 2000 条单行：

| 策略 | FlushCount | TotalFlushTimeMs | 每条 flush ms |
|---|---:|---:|---:|
| 每条一次 Flush(true) | 2000 | 466 | 0.233 |
| group-commit B=8 | 250 | 60 | 0.030 |
| group-commit B=16 | 125 | 29 | 0.015 |
| group-commit B=32 | 63 | 16 | 0.008 |
| group-commit B=64 | 32 | 7 | 0.004 |

单价几乎不随批次变大而上升：成本是 **fsync 次数**，不是这几十字节的写量。

10k×tiny、4 顶级目录（与 JournalPerformance 集成同构）：

| DOP | 墙钟 ms | TotalFlushTimeMs | FlushCount | overhead% | IsWithinTarget |
|---:|---:|---:|---:|---:|---|
| 1 | 121123 | 7482 | 20000 | 6.177 | true |
| 2（#40 推荐） | 61946 | 7422 | 20000 | **11.981** | **false** |
| 4 | 33789 | 7475 | 20000 | 22.123 | false |

分子跨 DOP 几乎不变（~7.4s），分母随并行下降，所以 **推荐 DOP=2 正好压在 10% 之上**。
#40 的 10k×1KB / 32 目录 DOP2 为 25.796%（墙钟更短、同样 ~7.3s flush）。

第二句柄 `ReadToEnd`：250 次递增读合计 1167ms（均 4.67ms）。此成本在分母、不在分子；只加速它会 **抬高** overhead%。

## 合法优化

**目录内 group-commit，B=32：**

1. 写最多 32 条 pending（仅缓冲）
2. **一次** `Flush(true)` —— 这批 pending 全部耐久
3. 第二句柄一次读，确认这批 pending 都可见
4. 再 `File.Delete`（任何删除都发生在该批 pending 已落盘之后）
5. 只给删除成功的文件写 commit
6. **一次** `Flush(true)` —— 这批 commit 耐久

崩溃语义（与 spec 一致，窗口按批放大，不放宽判据）：

- pending 已 flush、文件仍在 → resumable
- pending 已 flush、文件已不在、无 commit → uncertain（不得当成已删除）
- commit 已 flush → 已知删除
- **禁止** 在 pending 耐久之前删除

预期：FlushCount 从 `2N` 降到约 `2N/32`；DOP2 10k overhead 从 ~12% 降到 1% 量级。

不采用：`Flush(false)`、跳过 pending、改墙钟分母、选择性取样。

## 优化后（同机对照）

`flush-profile-after.json`，B=32：

| DOP | 墙钟 ms | TotalFlushTimeMs | FlushCount | overhead% | IsWithinTarget |
|---:|---:|---:|---:|---:|---|
| 1 | 8595 | 258 | 632 | 3.002 | true |
| 2 | 4301 | 262 | 632 | 6.092 | true |
| 4 | 1888 | 253 | 632 | 13.400 | false |

FlushCount 20000 → 632。推荐 DOP=2 的 10k 集成两组取样见 `journal-performance-report-10k.json`（7.875% / 6.229%）。DOP4 仍因线程求和口径超过 10%，警告路径生效。
