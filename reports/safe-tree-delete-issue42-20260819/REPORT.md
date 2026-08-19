# REPORT.md — #42 Phase 3 四阶段对比与生产基准

不是 GitHub 关单授权。数字全部来自版本化证据或本票新跑生产链路。

勘误：本文 2026-08-19 更新过一次，旧版只含迭代 1（接线首轮）数字；迭代 2b 与 AC11 复跑数字见「迭代 2b 与 AC11 复跑（2026-08-19 更新）」节。

## 口径

- 本票生产基准：10k × 4KB，完整 Plan→Apply→Purge，每场景 2 次。
- baseline = `-DisableApplyHashReuseForTest` + `-DisablePurgeHashReuseForTest`（复用关、并行关）。
- 典型 = 默认优化，DOP=2（`FromDetection` / #40 推荐）。
- 最佳 = 默认优化 + `-PurgeMaxDegreeOfParallelismForTest 4`。
- 生产删除器是 HostSafety lease，不是夹具 `File.Delete`。
- Phase1 / Phase2 引用既有 JSON，不重跑。

## 本票生产墙钟 — 迭代 1（接线首轮，2026-08-18/19）

来源：`benchmark.json` / `benchmark.stdout.txt`。

| 场景 | s1 合计 ms | s2 合计 ms | plan / apply / purge (s1) | 并行 |
| --- | ---: | ---: | --- | --- |
| baseline | 576238 | 579452 | 89150 / 265487 / 221601 | 否 |
| typical DOP2 | 232112 | 243245 | 88769 / 22129 / 121214 | 是，DOP=2，HostSafety deleter |
| best DOP4 | 236024 | 233293 | 96070 / 21984 / 117970 | 是，DOP=4，HostSafety deleter |

全管线（runner 用每组较小合计当中位数）：

- typical / baseline = 232112 / 576238 = **2.483x**（目标 ≥4x，未达）
- best / baseline = 233293 / 576238 = **2.470x**（目标 ≥6x，未达）

协调器自身墙钟（含在 purge 内，不是全管线分母）：

- typical s1/s2：3944ms / 3030ms
- best s1/s2：1780ms / （见 benchmark.json s2）

journal overhead（AC11 按典型 DOP2）：

- 迭代 1 当轮：typical s1 **7.175%**，s2 **9.604%**，当轮均 <10%，`IsWithinTarget=true`。「均 <10%」只适用于迭代 1 当轮，不能作为稳健结论（见下）。
- 迭代 2b：s1 8.47%，**s2 13.045%（超线）**（`iteration-2-benchmark.json`）。
- AC11 复跑（2026-08-19）：s1 **7.614%（达标）**，**s2 10.510%（超线，withinTarget=false）**（`ac11-rerun-benchmark.json`）。
- best DOP4：16.74% / 20.41%，不是 AC11 验收场景

本节表格与 2.483x/2.470x 为迭代 1（接线首轮）数字；迭代 2b 与 AC11 复跑的最新数字见下节「迭代 2b 与 AC11 复跑（2026-08-19 更新）」。

## 迭代 2b 与 AC11 复跑（2026-08-19 更新）

迭代 2b（C# preflight + 组内空目录收口）。来源：`iteration-2-benchmark.json`。分母仍为迭代 1 baseline 576238 / 579452ms：

| 场景 | s1 合计 ms | s2 合计 ms | plan / apply / purge (s1) | 倍率 |
| --- | ---: | ---: | --- | --- |
| typical DOP2 | 142049 | 143215 | 88030 / 21374 / 32645 | **4.057x / 4.023x**（metTypical=true） |
| best DOP4 | 146727 | 145426 | 95810 / 20973 / 29944 | **3.927x / 3.962x**（metBest=false，≥6x 未达） |

AC11 复跑（2026-08-19，仅典型 DOP2）。来源：`ac11-rerun-benchmark.json`：

| 场景 | s1 合计 ms | s2 合计 ms | plan / apply / purge (s1) | plan / apply / purge (s2) | 倍率 |
| --- | ---: | ---: | --- | --- | --- |
| typical DOP2 | 148175 | 147075 | 93032 / 22126 / 33017 | 93236 / 22161 / 31678 | **3.889x / 3.918x**（metTypical=false） |

typical-DOP2 journal overhead 全口径 6 样本：

| 轮次 | s1 | s2 |
| --- | ---: | ---: |
| 迭代 1（`benchmark.json`） | 7.175% | 9.604% |
| 迭代 2b（`iteration-2-benchmark.json`） | 8.47% | **13.045%** |
| AC11 复跑（`ac11-rerun-benchmark.json`） | 7.614% | **10.510%（withinTarget=false）** |

6 样本中 **3/6 ≥10%**：AC11（journal <10%）边界不稳，不能以单轮达标作稳健结论。

AC6（典型 ≥4x）：迭代 2b 当轮两样本达标（4.057x / 4.023x），AC11 复跑轮两样本 **3.889x / 3.918x 未达**。4x 属边界波动，主要来自 Plan 相位 88.0s→93.2s 的运行间噪声。

## 四阶段对比

| 阶段 | 来源 | 场景 | 墙钟 | 倍率 | 达票面 |
| --- | --- | --- | --- | --- | --- |
| Phase1 | #36 `scale-phase1.json` | 10k×160KiB 全管线 | baseline 598198 / phase1 944302 | **0.633x** | 未达 3x |
| Phase2 | #37 `scale-10000.json` | 10k×4KB Purge batch | batch 367363 / baseline 357701 | **0.974x** | 未达 1.2x / 3.5x |
| Phase3 夹具 | #40 raw / #41 20260819 | `File.Delete` DOP4 / journal DOP2 | 见原 JSON | 夹具 4.48x；journal 7.875% / 6.229%（#41 勘误后） | 不是生产删除 |
| Phase3 生产 | 本票 `iteration-2-benchmark.json` + `ac11-rerun-benchmark.json`（迭代 1 见 `benchmark.json`） | 10k×4KB 全管线 | baseline 576238 / typical 142049–148175 / best 145426–146727 | typical **4.057x / 4.023x**（iter2b）与 **3.889x / 3.918x**（复跑）；best **3.927x / 3.962x** | 4x 边界、6x 未达 |

#36 现场文件当前是 0.633x，不是 spec 操作者指南里曾写的 1.02x。本表跟当前 JSON，不改写历史叙事。

#42 0817 生产串行对照（接线前）：513510 / 534034 = 0.962x。本票接线首轮（迭代 1）典型 2.48x，Purge 协调器段从 ~220s 降到 3–4s，但 Plan≈90s 且 Purge 前 preflight/收口仍在，迭代 1 全管线到不了 4x。迭代 2b 换 C# preflight 后典型升至 4x 边界（见「迭代 2b 与 AC11 复跑」节）。

## 安全切片

`production-safety.json`：AC7 中断恢复、AC8 journal 可解析、AC9 TOCTOU 拒绝、AC10 端到端删净、AC12 网络能力降级串行，5/5 通过。

## 未达原因（不是测量把戏）

2026-08-19 更新（迭代 2b + AC11 复跑后的当前事实）：

- 典型 4x 在边界摆动：iter2b 当轮 4.057x / 4.023x 达标，AC11 复跑轮 3.889x / 3.918x 未达；差异主要来自 Plan 相位 88.0s→93.2s 的运行间噪声。
- 最佳 6x 结构性不可达：6x 需要全管线 ≤96s，Plan 单相位 88–96s 已占满或超出预算，加 Apply ≈21–22s 后无法达成。
- Plan 阶段并行哈希由 **#56** 承接（Plan 阶段并行哈希，方案草案未授权实施）；此前误归属 #31（FileIdentityV2 票，已关闭），已勘误。

迭代 1 时点的原叙述（保留供对照）：Apply+Plan 在优化路径上仍有 ~110s。典型合计 ~232s，要 ≤144s（4x）或 ≤96s（6x）还必须再砍 Plan/preflight。本票没有动那些合同，也没有用夹具 4.48x 冒充生产。
