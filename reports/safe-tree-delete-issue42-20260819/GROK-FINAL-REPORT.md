# GROK-FINAL-REPORT — GitHub #42 Phase 3 集成测试和生产验证

状态：`DONE_WITH_CONCERNS`

不是 GitHub 关单授权。未 commit / comment / close。

## 结论

生产 Purge 已按能力门控接入协调器，删除走 HostSafety lease。迭代 2 把 locked preflight 换成 Apply 同款 C# walker，并把空目录收口折进各分组尾部。对照迭代 1 baseline 576238ms：

- 典型 DOP2：**142049 / 143215 ms = 4.057x / 4.023x**（迭代 2b 当轮 ≥4x；AC11 复跑轮 3.889x / 3.918x 未达，AC6 判为边界，见勘误）
- 最佳 DOP4：**146727 / 145426 ms = 3.927x / 3.962x**（AC5 ≥6x 未达）

6x 需要全管线 ≤96s。Plan 单独仍是 88–96s，加上 Apply ≈21s 已超过 96s。Plan 哈希并行由 **#56** 承接（Plan 阶段并行哈希，方案草案未授权实施），本票不跨界；此前写「属 #31」系笔误（#31 是 FileIdentityV2 票，已关闭）。未掺夹具倍率。

## 第一部分：错误回滚已纠正

误把用户授权的 Grok host-lifecycle 改动 `git checkout` 回了 HEAD。已恢复：

- `managed/grok-hooks/host-lifecycle.json` 与 live `C:\Users\WINDOWS\.grok\hooks\host-lifecycle.json` 字节级一致（1580 字节），无 `codex-state-preflight`。未改 live。
- `tests/Test-GrokHostHooks.ps1` 已加回断言 `Grok host-lifecycle 不得注册 Codex state preflight`。`Test-GrokHostHooks.ps1` 复跑 exit=0。

新规则：这两个文件永远不得 checkout。快照恢复只覆盖 `reports/safe-tree-delete-*` 下被测试写脏的 tracked JSON。

## 14 条 AC

| # | 条件 | 结果 | 证据 |
| --- | --- | --- | --- |
| 1 | 完整优化路径性能测试套件（10k+ 小文件） | **通过** | `benchmark.json` 6 组 10k×4KB 生产 Plan→Apply→Purge |
| 2 | Baseline 原始实现跑完整 Plan→Apply→Purge | **通过** | baseline-s1 576238ms；s2 579452ms（复用关 + 并行关） |
| 3 | Phase3 最佳：本地 NTFS、4 线程 | **通过（有墙钟）** | best-dop4 s1 236024 / s2 233293；`parallelPurge.used=true` DOP=4 |
| 4 | Phase3 典型：本地 NTFS、2 线程 | **通过（有墙钟）** | typical-dop2 s1 232112 / s2 243245；DOP=2 |
| 5 | 最佳 ≤0.17（≥6x） | **未达** | 迭代 2b：146727 / 145426 → **3.927x / 3.962x**。6x 被 Plan 88–96s 卡住 |
| 6 | 典型 ≤0.25（≥4x） | **边界** | 迭代 2b：142049 / 143215 → **4.057x / 4.023x**（当轮达标）；AC11 复跑轮：148175 / 147075 → **3.889x / 3.918x**（未达，metTypical=false）。波动主要来自 Plan 相位 88.0s→93.2s 运行间噪声 |
| 7 | 并行 crash：强制中断后恢复正确 | **通过** | `production-safety.json` AC7：pending 可恢复，第二次 Purge 完成 |
| 8 | 并行 journal 完整可解析 | **通过** | 生产 `parallel-purge-journal-*/*.thread-*.jsonl` pending/commit 可解析 |
| 9 | TOCTOU：并行中改文件被拒绝 | **通过** | Apply 后改 quarantine 文件，Purge 以 identity/漂移失败，文件仍在 |
| 10 | 端到端全部删除无遗漏 | **通过** | 小树含 root+nested；10k `deleted=10000`；目标与 quarantine 消失 |
| 11 | Journal overhead <10%（典型 DOP2） | **边界不稳（3/6 超线）** | 迭代 1：7.175% / 9.604%；迭代 2b：8.47% / **13.045%**；AC11 复跑：7.614% / **10.510%（withinTarget=false）**。6 样本 3/6 ≥10%；DOP4 的 16–20% 不是本条验收场景 |
| 12 | 网络驱动器自动降级串行 | **通过** | `FromDetection(NTFS, remote=true)` → 串行 HostSafety，仍删完；无就绪 Network 实卷（#35 waiver） |
| 13 | 现有测试套件无回归 | **通过（waiver 除外）** | 27 fixture + ProductionSmoke；FileSystem #35 waiver；其余最终全绿 |
| 14 | baseline vs Phase1 vs Phase2 vs Phase3 对比 | **通过** | `REPORT.md`；Phase1/2 引用现役版本化 JSON，不重跑 |

## 基准最终数字

迭代 1 baseline（复用关+并行关，仍作分母）：576238 / 579452。

迭代 2b（C# preflight + 组内空目录收口）：

| 场景 | s1 | s2 | plan/apply/purge (s1) | snap/batch/coord/root |
| --- | ---: | ---: | --- | --- |
| typical DOP2 | 142049 | 143215 | 88030 / 21374 / 32645 | 2973 / 0 / 3213 / 31 |
| best DOP4 | 146727 | 145426 | 95810 / 20973 / 29944 | 2855 / 0 / 1703 / 34 |

迭代 2b 典型 journal：s1 8.47% / **s2 13.045%（超线）**。详见 `iteration-2-benchmark.json`、`iteration-2b-benchmark.stdout.txt`、`iteration-2-profile.md`。

AC11 复跑（2026-08-19，`ac11-rerun-benchmark.json`，仅典型 DOP2）：

| 场景 | s1 | s2 | plan/apply/purge (s1) | plan/apply/purge (s2) |
| --- | ---: | ---: | --- | --- |
| typical DOP2 | 148175 | 147075 | 93032 / 22126 / 33017 | 93236 / 22161 / 31678 |

复跑倍率 **3.889x / 3.918x**（metTypical=false）；复跑 journal s1 **7.614%（达标）** / s2 **10.510%（超线，withinTarget=false）**。

## 接线设计摘要

- 门控：`RecommendParallel` 且未关复用/并行，且非 empty-project-state、无 junction、无叶子测试钩子。
- 默认 DOP=2（#40 推荐）；`-PurgeMaxDegreeOfParallelismForTest 4` 只改推荐值。
- 每组持有顶级目录 `AcquireForEmptyDelete`；嵌套目录 `AcquireChildDirectoryForEmptyDelete`。根文件组在子目录组之后串行，避免祖先/后代 DELETE lease 冲突。
- journal 根：`<runDirectory>\parallel-purge-journal-<guid>`。恢复扫描全部此类目录；pending 无 commit + 路径在 → pending；路径不在 → uncertain。
- 失败不写 `purged`。CrashSafety 钩子在场时保持原串行 HostSafety。

## 改动清单

- `scripts/lib/CodexSafeTreeDeleteParallelPurge.cs`：5 参构造、HostSafety deleter 工厂、根组串行、DeletedRelativePaths
- `scripts/lib/CodexHookHandleBoundIO.cs`：`HostSafetyParallelPurgeLeafDeleter`（顶级 guard + 子目录 walk）
- `scripts/lib/CodexSafeTreeDelete.ps1`：Purge 门控接线、空目录收口、InFlightRecovery 读 thread journal
- `tests/Test-CodexSafeTreeDeletePhase3Integration.ps1`：证据目录与生产并行断言
- `tests/Test-CodexSafeTreeDeletePhase3Production.ps1`：AC7–12 小树（含 root+nested）
- 本目录：`DESIGN.md`、`DIAGNOSIS.md`、`REPORT.md`、`benchmark.json`、回归 JSON

未改 `modules/manifest.json`、性能 spec、policy。未碰 leftover `0ab1e1b6`。

## 证据目录

`reports/safe-tree-delete-issue42-20260819/`

## AC13 回归

- 首次全量：FileSystem 失败（#35 waiver）；14 项因陈旧 DLL「already exists」或嵌套 lease 冲突失败。
- 清 DLL + 顶级/子目录 guard 修复后复跑：Benchmark、HashSafely、LeafStreamSet、MetricsEvidence、PlanIdentityV2、Restore、SchemaCompatibility、Status、UncertainRecovery、PurgeBatch、PurgeHashReuse、Phase1、Phase3、ProductionSmoke **全部 0**。
- `git diff --check` 对本票源文件通过。
- 误 checkout 的 `host-lifecycle.json` / `Test-GrokHostHooks.ps1` 已按用户授权恢复，之后不再碰。
- 迭代 2 切片：GrokHostHooks、Coordinator、LeafStreamSet、Phase3Production、Benchmark、UncertainRecovery 全绿。
- 迭代 2 全量 27+Smoke：FileSystem #35 waiver；HashReuse 首次因 amortized identity `-ne` 假漂移失败，修后复跑 0；Phase3 因 #36 JSON 被测写脏失败，checkout 后复跑 0；ProductionSmoke 复跑 0。

## 风险与未决

- AC5 6x：Plan 88–96s + Apply 21s 已超过 96s。要 6x 必须把 Plan 降到约 40s（**#56**；原写 #31 系笔误）。本票停手。
- Purge 仍有约 26s 未计入 snap/coord（dispositions / manifest JSON / 目录 stream-set）。再压也救不了 6x。
- FAT32 / 网络实卷 e2e 仍是 #35 waiver。
- empty-project-state 仍走串行 HostSafety freeze journal。
- 未 commit / 未关 #42。

## 勘误（2026-08-19）

- AC11 原引用迭代 1 当轮数字（7.175% / 9.604%，当轮 <10%）；迭代 2b s2 **13.045%** 超线样本此前未披露。并入 AC11 复跑 7.614% / **10.510%** 后，典型 DOP2 六样本中 **3/6 ≥10%**，AC11 改判「边界不稳」。
- AC6：迭代 2b 当轮 4.057x / 4.023x 达标，但 AC11 复跑轮 **3.889x / 3.918x** 低于 4x（metTypical=false）；4x 属边界波动，主要来自 Plan 相位 88.0s→93.2s 的运行间噪声，AC6 改判「边界」。
- 归属修正：Plan 阶段并行哈希 **#31 → #56**。#31 是 FileIdentityV2 票（已关闭），原引用系笔误；#56（Plan 阶段并行哈希，方案草案未授权实施）承接。
