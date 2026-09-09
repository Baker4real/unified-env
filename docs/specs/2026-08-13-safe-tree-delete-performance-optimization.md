---
type: reference
title: 受管安全树删除性能优化
tags: [performance, safe-delete, hash-reuse, parallelization]
date: 2026-08-13
status: landed-mixed（Plan C# 单遍 walker 已落地；#56 按现状关闭；Status 的 #49 历史达标；#58 巨型 plan 优化已完成实现、三次 C# 冷启动和正式部署/live smoke 验收，完整参考 oracle、性能 A/B 与 live semantic digest 仍保留限制）
priority: P0
---

# 受管安全树删除性能优化

## Implementation status (2026-08-13)

（本节是 2026-08-13 时点快照；2026-08-19 起的现役状态以下文「Implementation status update (2026-08-19)」与「操作者指南」为准。）

Phase 1 的**库与 Plan 采集**部分已随 `e2064a3` 进入 `main`（GitHub #27–#31）：`FileIdentityV2`、`SessionHashCache`、`GetHashSafely`、Plan 并列 `fileIdentitiesV2`。2026-08-15 起（#54）Plan 再并列 `leafStreamSetV1`，Apply/Purge 在各自 locked preflight freeze 内逐 leaf 复验 stream 集、FileIdentityV2 与 hardlink 计数，并在 Purge 发布 `leaf-dispositions.json`。工作树 Apply 已接入 `GetHashSafely` + 会话级 `SessionHashCache`（#32，10k 0.868x）；Purge 已接入 invocation-local `SessionHashCache`（#33，10k 0.921x）。两者单独墙钟均未加速。#42 已改为 snapshot 持有 lease 时从同一 handle 算哈希。Crash recovery uncertain 已接入（#34）：尚未 commit-authorized 的 freeze 按路径是否仍在分为 `pendingFiles` / `uncertainFiles`，uncertain 不得收成 `purged`。#36 完整 Plan→Apply→Purge（10k×160KiB，每树 1.526 GiB）baseline 527846ms / Phase 1 517444ms = **1.02x**，未达 3x。#37 Purge 先收集 `List<PurgeFileLeaf>` 再 `GetHashSafely` 验证，删除仍走 HostSafety 逐 leaf freeze/commit；10k×4KB batch/Phase1/baseline = 187157/190905/180384ms（1.02x / 0.964x）。该 10k 墙钟测于一度尝试的 HostSafety collect-then-process，随后已撤回，未重跑。#38 已落地 `ThreadJournalWriter` / `ThreadJournalOwner`。#39 已落地 `ParallelPurgeCoordinator`（`scripts/lib/CodexSafeTreeDeleteParallelPurge.cs`）：夹具树上目录级 `Parallel.ForEach` + 每文件 pending→Flush→`File.Delete`→commit；10k 小文件 31339ms / 4 journal / 0 失败。允许根为构造注入；2-arg 仍默认 issue38 测试根。生产 `Invoke-CodexSafeTreeDeletePurge` 未接线。#40 在 coordinator 夹具上测完 1/2/4/8/16：10k×1KB 效率峰值 DOP 4（13255ms，4.48x），墙钟最佳 DOP 16（4926ms）；`FromDetection` optimize 仍为 4。#41 10k journal overhead **18.659%**。#42 生产路径 10k×4KB：baseline 513510ms / phase3-prod 534034ms = **0.962x**（未达 4x/6x）。snapshot 有 provider 时不再先放 lease，Apply/Purge 有 lease 时从同一 handle 算哈希。Coordinator 夹具 DOP4=4.48x 未计入生产倍率。生产 Purge 仍走 HostSafety，未接 `ParallelPurgeCoordinator`。操作者指南见下文「操作者指南」。不要把本 spec 的 4–6x 目标读成已上线性能。

2026-08-15 复核补丁（#54 跟进）：`leafStreamSetV1.consumptionBoundary` 增加
`requiresTreeManifestReverification='always'` 配对声明——stream-set 复验必须与 treeManifest
SHA-256/identity 复验配对消费，junction→junction 重定向仅由后者检出；冻结保证以 locked
preflight 为界，assert 与逐 leaf 删除之间的命名流增删不再复检，新增流随 leaf 销毁且不进审计
（临删前命名流存在性复检的成本评估属 #32/#33 范围）；file leaf 携带命名流（含下载文件常见的
`Zone.Identifier` ADS）在 Plan 即失败闭锁；`leaf-dispositions.json` 发布后、`purged` 落盘前的
崩溃窗口由绑定校验后的幂等收口覆盖，详见
`docs/specs/2026-07-24-safe-tree-delete-capability.md`。

## Implementation status update (2026-08-19)

#42 已把 `ParallelPurgeCoordinator` 接入生产 `Invoke-CodexSafeTreeDeletePurge`（能力门控 + HostSafety lease 删除器，非 `File.Delete`），并把 locked preflight 换成 Apply 同款 C# walker（`scripts/lib/CodexSafeTreeDeleteApplySnapshot.cs`）。同批收口：#32（Apply C# walker + 哈希复用：对 PS baseline ≈11.9x，主要来自 walker；同 walker 复用净效 1.10–1.12x）、#40（复测效率峰值 DOP=2，`RecommendOptimizeMaxParallelism` 已改 2/2/2）、#41（夹具 DOP2 journal 7.875% / 6.229%，勘误旧 18.659% 口径）。生产 10k×4KB 全管线对 baseline 576238ms：典型 DOP2 迭代 2b 轮 **4.057x / 4.023x**，AC11 复跑轮 **3.889x / 3.918x**（4x 边界摆动，Plan 相位噪声）；最佳 DOP4 **3.927x / 3.962x**。6x 在 #42 范围结构性不可达（Plan 单相位 88–96s 已占满 96s 预算），移交 #56（Plan 阶段并行哈希，方案草案未授权实施）。生产 journal overhead（典型 DOP2）三轮六样本 7.175–13.046%，2/6 ≥10%，边界不稳，稳健性复测归 #56（2026-08-27 勘误：原误记 3/6，原始 JSON 实为 2/6，超线样本 13.0457%/10.5100%；13.045% 为截断值，统一为 13.046% 四舍五入口径）。证据：`reports/safe-tree-delete-issue42-20260819/`、`reports/safe-tree-delete-parallelism-benchmark-20260819/`、`reports/safe-tree-delete-issue32-20260819/`、`reports/safe-tree-delete-issue41-20260819/`。

## Implementation status update (2026-08-27)

#56 Wave A 已落地：Plan 阶段默认走 C# 单遍 walker `scripts/lib/CodexSafeTreeDeletePlanSnapshot.cs`（`PlanTreeSnapshotBuilder`，串行 lease 哈希保留句柄复验；file leaf 同一 lease 句柄完成 identity+SHA-256+stream-set；directory/junction/'.' root 的 stream-set 走 per-path 重开与原 PS 第三遍同源；稳定 OrderBy+CurrentCultureIgnoreCase 平局保枚举序）。plan.json schema/字段/顺序/metrics 合同不变；wrapper（`Get-CodexSafeTreeDeletePlanTreeSnapshot` + 两个 FromCaptures 派生器）保持全部 fail-closed 消息逐字对齐。回退：库层 `-DisablePlanCSharpWalkerForTest` 与生产 env `CODEX_SAFE_TREE_DELETE_PLAN_CSHARP_WALKER=0`（任一信号即回 PS 三遍）。实测（10k×4KB，2026-08-27，当日磁盘偏慢 ~1.5×）：Plan 相位 C# min/med/max **9166/10286/10855ms**（≤32s 设计点与 ≤40s 硬顶双口径达标；PS 对照 131.6–143.6s，同盘加速中位 13.5×）；端到端暂定 typical 6.46–9.04×、best 5.31–6.79×，**正式 AC2 验收阻塞于环境锚点**（同轮 baseline 验证样本 901576ms，超 576238ms 常量 +56.5%，按计划作废计时样本待安静窗口重跑）。序列化 spike 判定 C# 序列化不触发（ConvertTo-Json 探针 0.46–0.58s）。Wave B（并行哈希）未触发。方案、四轮对抗审查与全部证据：`docs/plans/2026-08-27-safe-tree-delete-issue56-implementation.md`、`reports/safe-tree-delete-issue56-20260827/`。

史诗收口（#26）：实现关口 `DONE_WITH_CONCERNS`。子票 #32/#40/#41/#42 已于 2026-08-19 按结论评论关闭（典型 4x 边界、6x 移交 #56）；#36/#37/#43 已于 2026-08-20 按结论评论关闭（#36 按现役证据、#37 按被 #42 取代、#43 文档 16/16 落点）；#35 已于 2026-08-23 关闭（FAT32/网络实卷 waiver）。2026-08-17 时点的子票表见 `reports/safe-tree-delete-issue26-20260817/CLOSEABLE.md`（快照，不是现役状态）。

## 操作者指南

本节是落地后的操作合同。同文件后部 Problem / Solution / Compatibility Matrix 的 3x / 4x / 6x 是设计目标，不是已测生产倍率。删除语义、uncertain、`leafStreamSetV1` 楔死与 `fileIdentitiesV2` 缺节闭锁以 `docs/specs/2026-07-24-safe-tree-delete-capability.md` 为准；本节不复述那些段落。

### 三阶段实际落地

| 阶段 | 已落地 | 生产接线 | 已测墙钟 |
| --- | --- | --- | --- |
| Phase 1 哈希复用 | `FileIdentityV2`、Plan `fileIdentitiesV2`、`GetHashSafely`、invocation-local `SessionHashCache`（Apply #32、Purge #33） | 已接 Apply/Purge | #36 完整 Plan→Apply→Purge 10k×160KiB：版本化 `scale-phase1.json` = **0.633x**（钉 2026-08-17 已退役管线；早前叙事 1.02x 出自另一轮未版本化测量）；2026-08-19 现役管线（含 `ParallelPurgeCoordinator`）同协议重跑 = **3.845x**（ratio 0.26，metTarget=true；stdout 与守护哈希链见 `reports/safe-tree-delete-issue22-regression-20260819/`），#36 已于 2026-08-20 按此关闭 |
| Phase 2 批量 | Purge 先收集 `List<PurgeFileLeaf>` 再验证（#37） | 验证已接但生产默认被 C# walker 旁路（#42，见 Phase 3 行）；删除仍走 HostSafety 逐 leaf freeze/commit | 10k×4KB batch vs Phase1 **1.02x** / vs baseline **0.964x**（测于已撤回路径、未重跑，勘误见下文历史表注；版本化 `reports/safe-tree-delete-issue37-20260817/scale-10000.json` = **0.997x / 0.974x**），#37 已于 2026-08-20 按被 #42 取代关闭 |
| Phase 3 并行 | `ParallelPurgeCoordinator` + `ThreadJournalWriter` + C# preflight walker（#38–#42） | **已接**生产 `Invoke-CodexSafeTreeDeletePurge`（#42，2026-08-19；能力门控 + HostSafety lease 删除器） | 生产 10k×4KB 对 baseline 576238ms：典型 DOP2 **4.057x/4.023x**（iter2b）与 **3.889x/3.918x**（AC11 复跑），最佳 DOP4 **3.927x/3.962x**；4x 边界、6x 未达（→#56） |

生产 Purge 已按能力门控接入 `ParallelPurgeCoordinator`（见下节）；`RecommendParallel=false`、网络卷、empty-project-state、junction、CrashSafety 钩子在场时保持串行 HostSafety。

### FILE_ID_INFO

新 Plan 并列写出 `fileIdentitiesV2`：每个 file leaf 绑定 128-bit `FILE_ID_INFO`（`VolumeSerialNumber` + 16 字节 `FileId128`）以及同一句柄上 `GetFileInformationByHandle` 得到的 `FileSize` / `LastWriteTimeUtc`。`CapturedAtUtc` 不参与相等。缺少 `FILE_ID_INFO` 的卷上新 Plan 失败关闭。Apply/Purge 用该 identity 做 TOCTOU 门闩，再决定是否复用会话哈希。

### 哈希复用与会话缓存

`SessionHashCache` 只活在一次 Apply 或一次 Purge 调用内；两阶段不共享。键是 `FileIdentityV2`（内容相等，不是引用）。

无 lease 时走 `GetHashSafely`：`FileShare.None` 独占打开、不跟随 reparse；同一句柄读 identity；与 expected 不等则抛 `IdentityMismatchException` 且不读内容；缓存命中直接返回副本；未命中则 `ComputeHashFromHandle` 后写入缓存。该方法**不**对照 Plan 内容哈希——内容比对由 Apply/Purge 调用方对 treeManifest 做。

有 snapshot/Purge lease 时：先按路径复验 identity，命中缓存则跳过哈希；未命中则在同一 lease 上 `ComputeSha256FromHandle`，再写入缓存。

### 生产并行接线（#42，2026-08-19）

生产 `Invoke-CodexSafeTreeDeletePurge` 在满足门控时走 `ParallelPurgeCoordinator`：`RecommendParallel == true`、未用 `-DisablePurgeHashReuseForTest` / `-DisableParallelPurgeForTest`（任一在场即回退串行）、非 empty-project-state、无 junction、无叶子测试钩子。删除器是 HostSafety lease（顶级目录 `AcquireForEmptyDelete`、嵌套 `AcquireChildDirectoryForEmptyDelete`），不是夹具 `File.Delete`；根文件组在子目录组之后串行，避免祖先/后代 DELETE lease 冲突。默认 DOP=2（#40 2026-08-19 复测效率峰值），`-PurgeMaxDegreeOfParallelismForTest` 只改推荐值。journal 根为 `<runDirectory>\parallel-purge-journal-<guid>`，恢复扫描全部此类目录（pending 无 commit + 路径在 → pending；路径不在 → uncertain）。失败不写 `purged`；CrashSafety 钩子在场时保持原串行 HostSafety。`FileSystemCapabilities.RecommendParallel == false` 时 `ResolveMaxDegreeOfParallelism` 返回 1，生产与夹具都串行。coordinator 按顶层目录分组时只枚举文件，不含任何文件的顶层分支（含整树纯空目录）不产生分组；其目录由 PowerShell 侧 `Remove-CodexSafeTreeDeleteEmptyDirectoryTreeAfterParallelPurge` 在计数检查后、根删除前按 manifest 先叶后根幂等补删，逐目录保留 capability 与 identity 断言（resume 时 manifest 为存活子集）。该补删层于 2026-08-21 接线，修复此前该场景事务稳定卡在 purging/quarantined 的缺陷；回归测试覆盖纯空树、含空分支混合树、purging 中断恢复、Purge-mode 并行路径自证与仅 '.' 边界。

### Status 冷启动与大 plan 回退（#49 / #58）

生产 `Get-CodexSafeTreeDeleteStatus` 自 #49 起默认走 C# 并行 fast scan（`scripts/lib/CodexSafeTreeDeleteStatusScan.cs`，`StatusScanCoordinator`，DOP 为 min(4, cores-2)；2026-09-08 的 #58 工作区改动把共享 throttle 上限提至 min(8, cores-2)，该改动截至当日未提交）。归档记录复刻 terminal-archive 内容认证；未归档记录按参考顺序判定 plan 拒绝并保留 #48 拒绝后的只读观测链。fast scan 只处理 producer 规范形态输入；approved plan、异常 JSON 类型、深度超限、读失败和非规范属性形态仍回退 `Resolve-CodexSafeTreeDeleteStatusOperation`，不会把 approved plan 直接判为 terminal。

首次 plan snapshot 可注入调用内 prefetch，避免 fallback 开头重复读取；transaction approval 仍重新读取 plan/hash 与 policy，以检测首次扫描后的漂移。这不是整条认证链只读一次的合同。Status 复用随调用/进程结束，不使用 Apply/Purge 的 `SessionHashCache`，不持久化验证 receipt；程序集仍沿既有 Add-Type staleness 检查加载。

排障开关：`CODEX_SAFE_TREE_DELETE_STATUS_FAST_SCAN=0` 强制全量参考路径；`CODEX_SAFE_TREE_DELETE_STATUS_SEGMENTS=1` 输出 `statusSegments`。其中 `fastScanMs` 是完整扫描阶段计时，不能用内部 I/O 子段替代；`approvedPlanValidationReuseCount` 只表示 receipt 内容验证复用，不代表全量完成或性能达标。2026-09-08 的 #58 工作区新增 `CODEX_SAFE_TREE_DELETE_STATUS_TREE_FAST=0` 与 `CODEX_SAFE_TREE_DELETE_STATUS_PARALLEL_FALLBACK=0` 两个开关，回滚组合见下文 #58 段。

实测（协议 `reports/safe-tree-delete-issue49-20260823/protocol.md`，从属 20260817 协议）：正式 AC 三联（MED 修复后 cold-5/6/7，`cold-summary-post-fix.json`）三次独立冷启动墙钟 **9.762 / 9.791 / 9.237 s**（2960 operations 现场，优化前同日基线 199.357s；修复前三联 13.279/13.378/13.256 s 为历史样本，见 `cold-summary.json`），`metTarget=true`；fast 与参考路径对全部 operations 逐条对比零差异、blocking 集一致、evidence root 零写入、leftover transaction SHA 不变（等价性边界=producer 规范形态输入，非规范输入类回退参考路径，见协议）。证据：`reports/safe-tree-delete-issue49-20260823/`。

#### #58 内容验证复用与验收边界

`f6183ff` 的仓库源码引入 `StatusPlanValidationReceipt`，仅对已完成规范校验的 schema 1 plan 签发；receipt 绑定 plan 路径、SHA-256 和原文。Status 的 approved-plan reader 在只读审批模式、没有传入可变的 `PreparsedDocument` 且绑定匹配时复用严格 JSON 与 manifest 校验，由 reader 解析一次；异常分支按需解析。

v2/v3 transaction approval 可透传匹配 receipt，但保留 live plan read/hash 和 policy read。v2 policy SHA 漂移仍拒绝，v3 仍要求 schema 5 policy 并执行 namespace/journal 验证。非规范嵌套属性大小写回退参考路径，不改变 manifest SHA 对键名的敏感性；Apply/Purge/Restore 不消费此 receipt。

2026-09-06 的状态为 **源码已推送、全量验收失败**：6,039,074-byte plan 的局部探针结果等价；Status 32 项回归、基线与回滚各 24 项通过。但三次独立冷启动 `<60s` 验收在首轮 60.295s 超时并确认停止，后两轮未执行，没有完整 Status 输出。前后 evidence/policy 内容与 identity 相同，不等于期间零写事件审计。验收与计时勘误见 `reports/issue58-20260906/VERIFICATION.txt`；当前票状态以 [GitHub #58](https://github.com/Baker4real/unified-env/issues/58) 为准，#49 的历史数字不覆盖此规模。

2026-09-08 的状态为 **优化在工作区未提交、正式验收仍未通过**。本轮首次测出真实全量冷启动全程 84.6 分钟（4467 ops，exit 0；09-06 的 60.295s 是 deadline 截断值而非近似达标），主导热点是树快照递归内逐 entry 的 `Assert-CodexHookCapabilityPath`（`CodexHostSafety.ps1:884-887`，占总时 96.37%，O(entries×depth)）；SHA-256 内容哈希不是瓶颈（实测 1.4-1.6GB/s）。工作区改动（host-safety 所有权内 4 个跟踪文件 + `.gitignore`，宿主 gate shim 委托本仓库入口故工作区即运行态）：C# 树快照扫描器下沉（异常类型化回退 PS 参考路径）、receipt 快路径（commit 前 plan/txn/policy 三重 live 复核）、并行 fallback（runspace pool，前缀并查分组防嵌套树 lease 冲突，metrics 全缓冲合并）、plan manifest SHA 流式计算、免封送 receipt 核验（消除 PowerShell 方法绑定器对大 string 实参的整串深拷贝）。安静窗口实测 42.7s/54.2s；独立 verifier 正式三次冷启动 88.3/91.6/99.6s 均超 60s（本机慢态，I/O 分段膨胀），逐 op 等价 4467/4467、evidence 零写入、四套件（Status 42 项）全绿均 PASS。完全回旧串行行为需 `FAST_SCAN=0` + `PARALLEL_FALLBACK=0` + `TREE_FAST=0` 三开关全关。已知分叉：23 个生产 op 上纯参考解析器输出与冻结基线（C# fast scan 形状）不一致，修复与逐 op 等价验收冲突，已回退并双侧钉住（slice 41），方向待 issue owner 裁决。证据：`reports/issue58-20260908/`（FINDINGS.md、IMPLEMENTATION.md、acceptance-*；提交前为未跟踪）。

2026-09-09 的最终验收状态为 **DONE_WITH_CONCERNS**：最终源码完成三次独立 C# 冷启动，墙钟 **45.613 / 23.643 / 24.364 s**，三次均 exit 0、解析成功、job 为空，4467 operations 的 operation ID 与 semantic SHA 一致；Status 回归、buffer 归还边界、部署 fixture、模块边界和 `git diff --check` 均通过。正式 Bootstrap/Deploy 均 exit 0，receipt 为 `complete`，live closure SHA 为 `95d60477f6740b43ab2a17f43649bba8b4fc2e679aa276fbb3a261a9081b4d8f`（110 rows），marker 已清除，live Status smoke exit 0。完整 PS reference 在 180 秒边界内超时，未形成完整慢 oracle 输出；性能 A/B 只有一次方向性证据，live operation ID digest 为截断值且 semantic comparison 对编码敏感，均不作更强声明。最终证据汇总见 `reports/issue58-20260909-execution/final-acceptance-20260909.json`，部署回读见同目录 `live-deployment-20260909.readback.json`。

宿主 gate shim 直接委托本仓库入口，源码落盘会改变后续调用可加载的代码；“未执行 Deploy”不表示新源码与宿主隔离。正式部署记录和真实入口验收分别按 capability spec 的部署合同核验，本次局部测试与 Git 发布不代替这些步骤。

### 文件系统探测

`FileSystemDetector.DetectFileSystem` 读 `DriveInfo.DriveFormat`、`DriveType == Network`，并对目标路径试 `GetFileIdentityV2`。`FromDetection` 现役规则：

- FAT32 / exFAT：`SupportsFileId128` 强制为 false，`DeletionAllowed` 为 false。
- 本地 NTFS / ReFS 且探测到 `FILE_ID_INFO`：`RecommendHashReuse` / `RecommendParallel` 为 true，`RecommendedMaxParallelism` 为 2（#40 2026-08-19 复测效率峰值 2/2/2，取代旧值 4；不是墙钟最快的 16）。
- 网络卷或非 NTFS 族：两项 Recommend 为 false，并行度建议为 1；只要 `FILE_ID_INFO` 可用且非 FAT 族，`DeletionAllowed` 仍可为 true。

生产 Plan / Apply / Purge 只把 `DeletionAllowed` 当硬门（`Assert-CodexSafeTreeDeleteDeletionAllowed`）。`RecommendHashReuse` **不**关掉生产哈希复用；`RecommendParallel` 自 #42 起门控生产 Purge 并行（false → 串行 HostSafety），也约束夹具 coordinator。FAT32 / 网络实卷 e2e 有维护者 waiver，未提权验证（#35）。

### 实测性能（典型 4x 边界，6x 未达 → #56）

**生产 Plan→Apply→Purge（2026-08-19 接线后，HostSafety lease 删除器）**

| 来源 | 场景 | 墙钟 | 倍率 | 是否达票面 |
| --- | --- | --- | --- | --- |
| #42 iter2b | 10k×4KB 完整流水线，典型 DOP2 | 142049 / 143215ms（baseline 576238ms） | **4.057x / 4.023x** | 达 4x（当轮） |
| #42 AC11 复跑 | 同上 | 148175 / 147075ms | **3.889x / 3.918x** | 4x 边界摆动（Plan 相位 88→93s 噪声） |
| #42 iter2b | 同上，最佳 DOP4 | 146727 / 145426ms | **3.927x / 3.962x** | 未达 6x（→#56） |

JSON：`reports/safe-tree-delete-issue42-20260819/iteration-2-benchmark.json`、`ac11-rerun-benchmark.json`（后者内部 `artifactType` 沿用 iteration2 命名，按文件名区分轮次）。

**接线前历史（HostSafety 串行 Purge）**

| 来源 | 场景 | 墙钟 | 倍率 | 是否达票面 |
| --- | --- | --- | --- | --- |
| #36 | 10k×160KiB 完整流水线 | baseline 598198ms / Phase1 944302ms | **0.633x**（现役 `scale-phase1.json`；早前叙事 1.02x 出自另一轮未版本化测量） | 未达 3x |
| #42 0817 | 10k×4KB 完整流水线（接线前） | baseline 513510ms / phase3-prod 534034ms | **0.962x** | 未达 4x/6x |
| #32 0817 | Apply 10k×4KB（PS 走树） | reuse 349164ms / baseline 302992ms | **0.868x** | 未达 1.5–2x |
| #32 0819 | Apply 10k×4KB（C# walker） | 对 PS baseline ≈**11.9x**（主要来自 walker）；同 walker 复用净效 **1.10–1.12x** | 见 `issue32-20260819/scale-10000.json` | 复用票面达标口径见该票结论评论 |
| #33 | Purge 10k×4KB | reuse 224320ms / baseline 206496ms | **0.921x** | 未加速 |
| #37 | Purge batch 10k×4KB | batch 187157 / Phase1 190905 / baseline 180384ms | **1.02x** / **0.964x** | 未达 1.2x / 3.5–4x |

JSON：`reports/safe-tree-delete-issue36-20260817/scale-phase1.json`、`reports/safe-tree-delete-issue42-20260817/scale-phase3.json`、`reports/safe-tree-delete-issue32-20260817/scale-10000.json`、`reports/safe-tree-delete-issue32-20260819/scale-10000.json`、`reports/safe-tree-delete-issue33-20260817/scale-10000.json`、`reports/safe-tree-delete-issue37-20260817/scale-10000.json`。#37 的 10k 墙钟测于一度尝试的 HostSafety collect-then-process，随后已撤回，未重跑。

**Coordinator 夹具与 journal**

| 来源 | 场景 | 结果 | 备注 |
| --- | --- | --- | --- |
| #40 20260819 | 生产删除器 DOP 扫描 | 效率峰值 **DOP2**（小/中/大文件 2/2/2），数据不支持升 DOP4 | `parallelism-benchmark-20260819/analysis.json`；`RecommendOptimizeMaxParallelism` 已按此改 2 |
| #40 20260817 | `File.Delete` 夹具 10k×1KB | DOP4 4.48x；墙钟最快 DOP16 | 已被 20260819 生产删除器复测取代，不再作推荐依据 |
| #41 20260819 | 夹具 DOP2 journal overhead | **7.875% / 6.229%**（<10%） | 旧叙事 18.659% / 6.166% / 6.397% 已在 #41 关单勘误 |
| #42 生产 journal | 典型 DOP2 三轮六样本 | 7.175 / 9.604 / 8.47 / 13.046 / 7.614 / 10.510% | **2/6 ≥10%，边界不稳**（2026-08-27 勘误：原误记 3/6，原始 JSON 实为 2/6）；稳健性复测归 #56 |

#35 FAT32/网络实卷 e2e 有维护者 waiver，未提权验证，不列入倍率表。

### 故障排查

| 触发 | 先做什么 | 仍失败 |
| --- | --- | --- |
| 目标在网络卷，或担心并行 | 网络卷 `RecommendParallel=false`，生产 Purge 自动回退串行 HostSafety；无独立"关并行"开关，测试面用 `-DisableParallelPurgeForTest` | 网络实卷 e2e 未提权验证（#35）。无 `FILE_ID_INFO` 时新 Plan 失败关闭，不要改走未受管删除 |
| 非 NTFS，或报 `FILE_ID_INFO` / `DeletionAllowed` | 读抛错：FAT32/exFAT 与探测失败都会让新 Plan 失败关闭 | 换到支持 `FILE_ID_INFO` 的本地 NTFS/ReFS 后重新 Plan。不要注入 `FileSystemCapabilitiesForTest` 绕过生产门闩 |
| journal flush 慢、overhead ≥10% | 生产并行 Purge 有 thread journal（`parallel-purge-journal-*`）：典型 DOP2 六样本 2/6 ≥10%（2026-08-27 勘误：原误记 3/6），边界不稳属已知状态（#56 复测），单次超线不代表故障。夹具 DOP2 口径为 7.875%/6.229% | 持续显著超线先看磁盘延迟；串行 HostSafety 回退路径无此 flush 占比合同 |
| 恢复列出 `uncertainFiles`，或 Status 为 `manual-review` / `inconsistent` | 按能力 spec 的 pending / uncertain 段：路径已不在且尚未 `commit-authorized` 的 freeze 不得当成已删除，也不得收成 `purged`。手工核验该路径后重新 Plan，或保持 `manual-review` | 缺 `leafStreamSetV1` 的在途会 wedge。不要 Purge leftover |

### 迁移

Apply/Purge 读到旧 Plan 缺 `fileIdentitiesV2` 或 `leafStreamSetV1` 时失败闭锁（票面所称 schema v4 evidence 即这类缺节 Plan）。完成标准：对该目标重新 Plan，得到两节齐全的新 Plan 后再 Apply。Status / Archive 只读路径不受缺节影响。

`purging` 且 quarantine 已缺失、Plan 又无 `leafStreamSetV1` 的在途会永久 wedge（能力 spec 已写合同）。完成标准：部署前先把在途事务收尾清空；已经 wedge 的保持 `manual-review`，重新 Plan 新目标。不要对 leftover quarantine 做未授权 Purge。

### 发布说明

- **已测生产倍率（2026-08-19）**：#42 10k×4KB 典型 DOP2 = 4.057x/4.023x（iter2b）与 3.889x/3.918x（复跑），4x 边界；最佳 DOP4 = 3.927x/3.962x，未达 6x（→#56）。#36 10k×160KiB：版本化 JSON = 0.633x（钉 2026-08-17 已退役管线）；现役管线同协议重跑 = **3.845x**（metTarget=true，证据见 `reports/safe-tree-delete-issue22-regression-20260819/`），#36 已于 2026-08-20 按此关闭。
- **已接生产**：128-bit `FILE_ID_INFO`、`fileIdentitiesV2`、`leafStreamSetV1`、Apply/Purge 会话哈希复用、C# preflight walker、`ParallelPurgeCoordinator`（HostSafety lease 删除器，默认 DOP=2）、thread journal 恢复扫描、lease 同句柄哈希。
- **仅夹具**：`File.Delete` 版 coordinator 基准（#40 20260817 的 4.48x）不代表生产删除加速；生产口径以 20260819 证据为准。
- **破坏性**：缺 `fileIdentitiesV2` / `leafStreamSetV1` 的旧 Plan 必须重新 Plan。缺 `leafStreamSetV1` 的在途会 wedge。

### API 契约

真源是 `scripts/lib/CodexSafeTreeDeleteFileIdentity.cs`、`scripts/lib/CodexSafeTreeDeleteHashCache.cs` 的 XML/实现，以及 `scripts/lib/CodexHookHandleBoundIO.cs` 的 lease 方法。PowerShell 包装为 `Get-CodexSafeTreeDeleteFileIdentityV2` / `Get-CodexSafeTreeDeleteHashSafely`。

**`FileIdentityReader.GetFileIdentityV2`**

| 重载 | 参数 | 返回 | 异常 |
| --- | --- | --- | --- |
| `(string path)` | 非空路径；`CreateFileW` 以 `GenericRead` + `FileShare.ReadWrite\|Delete` + `FILE_FLAG_BACKUP_SEMANTICS\|FILE_FLAG_OPEN_REPARSE_POINT` 打开 | `FileIdentityV2` | 空路径 → `ArgumentException`；打开失败或无 `FILE_ID_INFO` → `Win32Exception` |
| `(SafeFileHandle handle)` | 有效句柄 | 同上；`FileId128` 来自 `GetFileInformationByHandleEx`（`FileIdInfo=18`）；size/mtime 来自 `GetFileInformationByHandle`；`CapturedAtUtc=UtcNow` | 无效句柄 → `ArgumentException`；查询失败 → `Win32Exception` |

**`FileHashComputer.GetHashSafely(filePath, expectedIdentity, sessionCache)`** — 见源码 XML。独占 `FileShare.None`，不跟随 reparse；identity 不等 → `IdentityMismatchException` 且不读内容；缓存命中不哈希。空路径 / null identity / null cache → `ArgumentException` / `ArgumentNullException`；打开失败 → `Win32Exception`。

**`FileHashComputer.ComputeHashFromHandle(handle)`** — 见源码 XML。调用前 seek 到 0，返回前再 seek 到 0。同一句柄并发调用不安全。无效/已关句柄 → `ArgumentException`；seek/read 失败 → `Win32Exception`。

**`ComputeSha256FromHandle`**（`SafeTreeDeleteFileLease` / `GuardedReadOnlyFileLease` / `GuardedTargetFileLease`）— 先把 `stream.Position` 置 0，再 `SHA256.ComputeHash(stream)`。哈希后指针停在 EOF，**不会**回到 0。与 `ComputeHashFromHandle` 的复位合同不同。

**`FileSystemCapabilities` 字段**

| 字段 | 含义 |
| --- | --- |
| `FileSystemType` | `DriveInfo.DriveFormat`（如 NTFS / ReFS / FAT32） |
| `IsRemote` | `DriveType == Network` |
| `SupportsFileId128` | 探测到 `FILE_ID_INFO` 且非 FAT32/exFAT |
| `RecommendHashReuse` | 仅本地 NTFS/ReFS 且 `SupportsFileId128`；生产 Apply/Purge 不读此字段 |
| `RecommendParallel` | 同上；false 时生产 Purge 与夹具 coordinator 都串行（DOP=1） |
| `RecommendedMaxParallelism` | 可优化时为 2（#40 2026-08-19 复测修订，原 4），否则 1 |
| `DeletionAllowed` | 等于 `SupportsFileId128`；生产硬门 |

## Problem Statement

用户在使用 Codex 受管安全树删除系统删除 GB 级数据（包含数万+小文件）时，删除操作耗时超过 1 小时，严重影响工作流效率。

根本原因是当前实现的性能瓶颈：
1. **哈希读取放大**：每个文件被读取 7 次（Plan 1次 + Apply 3次 + Purge 3次）计算 SHA-256
2. **串行处理**：PowerShell 循环串行处理每个文件，无法利用多核性能
3. **PowerShell 开销**：每个文件的循环、对象创建和函数调用开销累积

用户场景是本地 NTFS 驱动器上的 GB 级目录树，包含数万个小文件（典型场景：node_modules、构建产物、.NET 缓存）。

## Solution

通过三个优化阶段将删除时间从 60 分钟降低到 10-15 分钟（4-6x 提升），同时保持所有安全保证：

**Phase 1: 安全哈希复用**（目标 3x）
- 升级 file identity 到 128-bit FILE_ID_INFO（VolumeSerialNumber + FileId + Size + LastWriteTime）
- Apply/Purge 阶段首次验证时重新计算哈希，验证通过后在会话内复用
- 将 7 次哈希读取降低到 4-5 次（Plan 1次 + Apply 1次验证 + Purge 3次复用）

**Phase 2: 批量处理优化**（累积 4x）
- Purge 阶段批量收集删除项，减少 PowerShell 循环和对象创建开销
- 批量验证和批量 journal 写入

**Phase 3: 受限并行化**（累积 6x）
- 目录级并行删除（4-8 线程），避免文件级并发的 journal 复杂度
- 每线程独立 journal 文件，立即 flush 保证 crash safety
- 文件系统检测和自动降级机制

所有优化必须保持现有安全保证：
- Content-authenticated deletion (SHA-256 验证)
- Crash safety (transaction journal)
- TOCTOU 防御（独占文件锁）
- Policy 授权边界

## User Stories

1. As a Codex user, I want to delete large temporary directories (node_modules, build outputs) in under 15 minutes, so that I can quickly clean up disk space without waiting an hour
2. As a Codex user, I want the deletion to remain safe and verifiable, so that I never accidentally delete the wrong files even with performance optimizations
3. As a Codex user, I want crash recovery to still work after optimization, so that interrupted deletions don't leave my system in an inconsistent state
4. As a system administrator, I want file identity verification to use Windows FILE_ID_INFO, so that identity checks are reliable across file moves and modifications
5. As a developer, I want hash reuse to only happen after identity verification passes, so that TOCTOU vulnerabilities are prevented
6. As a developer, I want hash reuse to be session-scoped, so that different Apply/Purge sessions don't incorrectly reuse stale hashes
7. As a Codex user, I want the system to detect my file system type (NTFS/ReFS/FAT32/Network), so that optimizations are only enabled when safe
8. As a Codex user on a network drive, I want the system to automatically disable hash reuse and parallelization, so that I don't encounter file system compatibility issues
9. As a Codex user, I want parallel deletion to respect directory boundaries, so that journal integrity is maintained
10. As a Codex user, I want each parallel thread to have its own journal file, so that concurrent writes don't corrupt the transaction log
11. As a Codex user, I want journal writes to flush immediately to disk, so that crash recovery can reconstruct the exact deletion state
12. As a Codex user, I want the optimization to benchmark my specific hardware, so that parallelism degree is tuned to my CPU core count
13. As a developer, I want crash recovery to handle "uncertain" files (pending but no longer exist), so that manual verification is required rather than assuming completion
14. As a developer, I want file handles to use FileShare.None during validation, so that no other process can modify the file during the verification window
15. As a developer, I want the Delete/Journal sequence to be atomic (pending → delete → commit), so that crash recovery knows exactly which files were successfully deleted
16. As a Codex user, I want journal flush performance to be monitored, so that if journal overhead exceeds 10% of total time, I'm warned about potential disk bottlenecks
17. As a developer, I want FILE_ID_INFO P/Invoke structures to use embedded value types, so that memory layout is correct and GetFileInformationByHandleEx works reliably
18. As a developer, I want GetFileIdentityV2 to use GetFileInformationByHandle for size/mtime, so that the code compiles and runs correctly
19. As a developer, I want ComputeHashFromHandle to document its stream position contract, so that callers know the handle position is reset to 0 after use
20. As a developer, I want FileIdentityV2 to implement IEquatable correctly, so that session cache lookups work with byte array content comparison
21. As a developer, I want ThreadJournalWriter lifecycle to use ThreadLocal with proper cleanup, so that no journal handles are leaked even on exceptions
22. As a Codex user, I want the performance gain to be measured and reported, so that I know if the optimization delivered the expected 4-6x improvement
23. As a system administrator, I want policy entries to specify minimum quarantine age, so that accidental deletions have a recovery window
24. As a system administrator, I want producer fence modes (manual-only vs os-handle-required), so that batch purge only works when producers are cooperating
25. As a Codex user, I want legacy Plan artifacts (v1/v2/v3) to be automatically rejected, so that I must re-plan with the new identity system
26. As a developer, I want the implementation to fail fast on unsupported file systems, so that users get clear error messages rather than silent data loss
27. As a Codex user, I want Apply phase to detect cloud sync placeholders (OneDrive/Dropbox), so that I'm warned about potential sync conflicts
28. As a developer, I want parallelism tests to benchmark 1/2/4/8/16 thread configurations, so that the optimal degree is empirically determined
29. As a Codex user, I want the first deployment to be conservative (hash reuse only), so that risk is minimized before enabling parallelization
30. As a Codex user, I want comprehensive testing on real-world scenarios (10k+ files), so that performance gains are validated before production rollout

## Implementation Decisions

### Module Modifications

**`scripts/lib/CodexSafeTreeDelete.ps1`**
- Add `FileIdentityV2` structure with 128-bit FILE_ID_INFO fields
- Add `SessionHashCache` for in-memory hash reuse within Apply/Purge sessions
- Add `GetHashSafely` function implementing the safe hash reuse protocol
- Add `FileSystemCapabilities` detection and automatic degradation
- Add `ParallelPurgeCoordinator` for directory-level parallel deletion
- Add `ThreadJournalWriter` with ThreadLocal lifecycle management
- Modify `Invoke-CodexSafeTreeDeletePlan` to capture FileIdentityV2
- Modify `Invoke-CodexSafeTreeDeleteApply` to use GetHashSafely and optional parallelization
- Modify `Invoke-CodexSafeTreeDeletePurge` to use GetHashSafely, batch processing, and optional parallelization

**`scripts/Invoke-CodexSafeTreeDelete.ps1`**
- Add file system detection call before Plan phase
- Add warnings for non-optimal file systems (network drives, FAT32, non-FILE_ID_INFO)
- Add performance monitoring and reporting

**`managed/safe-tree-delete/policy.json`**
- Upgrade schema version to v5 (if not already)
- Ensure all entries have `minimumQuarantineAgeMinutes` and `producerFenceMode`

**Evidence directory structure**
- Thread journals: `transaction-{id}.thread-{tid}.dir-{name}.json`
- Main journal checkpoint: `transaction-{id}.checkpoint.json`
- Performance metrics: `transaction-{id}.perf.json`

### Technical Clarifications

**FILE_ID_INFO Interop**
- Use embedded `FILE_ID_128` struct with 16 individual byte fields (B0-B15), not `byte[]` managed array
- P/Invoke must use `GetFileInformationByHandleEx` with `FILE_INFO_BY_HANDLE_CLASS.FileIdInfo = 18`
- Size and mtime must come from `GetFileInformationByHandle` returning `BY_HANDLE_FILE_INFORMATION`
- FILETIME conversion: `((long)dwHighDateTime << 32) | dwLowDateTime` then `DateTime.FromFileTimeUtc`

**Hash Reuse Protocol**
1. Open file with `FileShare.None` exclusive lock
2. Get current `FileIdentityV2` from handle
3. Check session cache with identity as key
4. If cache hit AND identity matches: return cached hash (no re-hash)
5. If cache miss OR identity mismatch: recompute hash from handle, verify against Plan hash, cache on success

**ComputeHashFromHandle Contract**
- Input: handle at any position
- Output: SHA-256 hash as byte[]
- Side effect: handle position reset to 0
- Thread safety: unsafe for concurrent calls on same handle

**FileIdentityV2 Equality**
- Implement `IEquatable<FileIdentityV2>`
- `Equals`: compare VolumeSerialNumber, FileSize, LastWriteTimeUtc, and FileId128.SequenceEqual()
- `GetHashCode`: combine VolumeSerialNumber, FileSize, LastWriteTimeUtc, and first 8 bytes of FileId128
- CapturedAtUtc does NOT participate in equality

**ThreadJournalWriter Lifecycle**
- Use `ThreadLocal<ThreadJournalWriter>(trackAllValues: true)` to store per-thread instances
- Each directory creates a fresh journal writer (no cross-directory reuse)
- `finally` block disposes all thread values after `Parallel.ForEach`
- Coordinator implements `IDisposable` and calls `threadJournals.Dispose()`

**Delete/Journal Atomicity**
- Sequence: `WritePending() → Flush() → File.Delete() → WriteCommit() → Flush()`
- Pending entry must hit disk before OS delete syscall
- Commit entry must hit disk before function returns
- Crash between pending and commit: recovery finds pending entry, file existence determines resumability

**Crash Recovery Uncertain State**
- If pending entry exists but file does not exist: mark as "uncertain"
- Cannot assume "we deleted it" — could be another process
- Recovery returns `UncertainFiles` list requiring manual verification
- Only committed entries or pending entries with existing file (after hash re-verification) count as known state

**File System Detection and Degradation**
- Detect: `DriveInfo.DriveFormat` (NTFS/ReFS/FAT32), `DriveType` (Local/Network), test FILE_ID_INFO support
- Local NTFS with FILE_ID_INFO: enable hash reuse + parallelization
- Network drive: disable hash reuse, disable parallelization, warn user
- Non-NTFS or no FILE_ID_INFO: disable hash reuse, allow parallelization with warning
- Removable media: conservative mode (no optimizations)

**Parallelism Configuration**
- Directory-level parallelism only (files within a directory still serial)
- `MaxDegreeOfParallelism = min(4, Environment.ProcessorCount - 2)` as starting point
- Week 3 benchmarks will tune this based on 1/2/4/8/16 thread tests
- Each thread gets its own journal file with immediate flush

**Journal Performance Monitoring**
- Track total flush time and flush count per thread
- Compute `journalOverheadPercent = totalFlushTime / totalElapsedTime`
- Fail acceptance test if overhead > 10%
- Log slow flushes (>100ms) for diagnosis

**Schema Compatibility**
- Plan v4 (current) → v5 (optimized): breaking change, must re-plan
- Policy v4 → v5: add required fields, validate in activation
- Evidence v1 unchanged (metrics and journal schemas extend independently)

### Architectural Decisions

**Why 128-bit FILE_ID_INFO instead of 64-bit?**
- 64-bit FileIndex can be reused after delete/recreate on NTFS
- 128-bit FILE_ID_INFO is globally unique and stable across volume lifetime
- Eliminates risk of false identity match leading to wrong file deletion

**Why session-scoped cache instead of persistent?**
- Persistent cache would need invalidation on file modification (complex)
- Session scope is simple: cache lives only during one Apply or Purge run
- Re-verification on first use in each session provides safety

**Why directory-level parallelism instead of file-level?**
- File-level would require complex journal coordination (lock-free queue or mutex)
- Directory-level is simpler: each thread owns its files, independent journal
- Still achieves most of the speedup (directories naturally partition the work)

**Why not use C# for the hot path?**
- PowerShell module boundary is already established
- C# would require native module, deployment complexity
- Optimization focus is reducing I/O (7x → 4x hashing), not execution speed
- If PowerShell overhead remains after Phase 1-2, Phase 3+ can consider C#

**Why immediate journal flush instead of batching?**
- Crash safety requires pending entry on disk before delete syscall
- Batching would introduce correctness risk (delete happens before journal written)
- Modern SSDs handle small sequential writes efficiently
- Performance monitoring (Week 3) will confirm <10% overhead

**Why three-phase rollout (hash reuse → batch → parallel)?**
- Risk management: each phase independently testable
- If Phase 1 delivers 3x, user pain is already reduced
- Phase 2 and 3 can be delayed if risk/complexity too high
- Allows early production validation before full optimization

## Testing Decisions

### What Makes a Good Test

Tests should verify **external observable behavior**, not implementation details:
- ✅ "After Purge, target directory does not exist"
- ✅ "After crash during Apply, recovery correctly resumes"
- ✅ "Hash reuse only happens when identity matches"
- ❌ "SessionHashCache internal dictionary has correct key"
- ❌ "ThreadJournalWriter calls Flush exactly twice per file"

Tests should use **realistic data volumes** for performance tests:
- Unit tests: 10-100 files
- Integration tests: 1,000 files
- Performance tests: 10,000+ files (actual user scenario)

Tests should verify **safety properties** hold under optimization:
- Content-authenticated: wrong file never deleted
- Crash safety: recovery never produces inconsistent state
- TOCTOU: file modified between identity check and delete → fails safely

### Modules to Test

**Core hash reuse logic** (`GetHashSafely`, `SessionHashCache`)
- Identity match → hash reuse works
- Identity mismatch → hash recomputed
- Hash mismatch → exception thrown
- Cache isolation between sessions

**Parallel coordination** (`ParallelPurgeCoordinator`, `ThreadJournalWriter`)
- Correct parallelism degree
- No journal corruption under concurrency
- Exception in one thread → other threads clean up
- All journal handles disposed on exit

**Crash recovery with uncertain state**
- Pending file exists → resumable
- Pending file missing → uncertain (not assumed deleted)
- Committed file missing → counted as deleted
- Recovery returns correct classification

**FILE_ID_INFO interop**
- GetFileIdentityV2 returns correct 128-bit FileId
- Identity equality uses content comparison (not reference)
- Works on NTFS, ReFS
- Fails gracefully on FAT32 or network drives without FILE_ID_INFO

**File system detection**
- Detects NTFS/ReFS/FAT32/Network correctly
- Recommends correct optimization level
- Warns on non-optimal file systems

**Performance benchmarks**
- Baseline (current): measure on 10k file tree
- Phase 1 (hash reuse): verify 3x improvement
- Phase 2 (batch): verify cumulative 4x improvement
- Phase 3 (parallel): verify cumulative 6x improvement
- Journal overhead: verify <10% of total time

### Prior Art for Tests

Existing test files provide patterns:
- `tests/Test-CodexSafeTreeDelete.ps1`: Plan/Apply/Purge integration tests
- `tests/Invoke-CodexSafeTreeDeleteCrashFixture.ps1`: Crash recovery scenarios
- `tests/Test-CodexSafeTreeDeleteBenchmark.ps1`: Performance measurement harness

New tests should follow these patterns:
- Use fixture functions to create test directory trees
- Use `Measure-Command` for performance measurements
- Use evidence directory inspection to verify journal correctness
- Use `try/finally` to ensure test cleanup even on failure

Specific test additions:
- `Test-CodexSafeTreeDeleteHashReuse.ps1`: Verify hash reuse protocol
- `Test-CodexSafeTreeDeleteParallel.ps1`: Verify parallel correctness and performance
- `Test-CodexSafeTreeDeleteFileSystemDetection.ps1`: Verify detection and degradation
- `Test-CodexSafeTreeDeleteIdentityV2.ps1`: Verify FILE_ID_INFO interop

## Out of Scope

**Not included in this optimization:**
- Optimizing Plan phase (still 1x hash read per file) — Plan is run once, Apply/Purge are run repeatedly（2026-08-27 起由 #56 Wave A 修订：Plan 阶段已换 C# 单遍 walker，串行 lease 哈希，见「Implementation status update (2026-08-27)」与 `reports/safe-tree-delete-issue56-20260827/`）
- Cross-session persistent hash cache — too complex, invalidation unclear
- File-level parallelization — journal coordination complexity too high（#56 Wave B 若触发须先修订本条与 L468 并满足 `docs/plans/2026-08-27-safe-tree-delete-issue56-implementation.md` §4 前置硬门）
- C# rewrite of deletion/journal semantics remains excluded; Plan #56 and Status #49/#58 cover their documented read-only traversal and validation work, retaining PowerShell ownership and lease boundaries for mutations.
- BatchPurge optimization remains separate. The original Status exclusion was superseded by #49 and the #58 regression work documented in the operator guide.
- Supporting file systems other than NTFS/ReFS — FAT32 and network drives get conservative fallback
- Windows 7 support — FILE_ID_INFO requires Windows 8+, older systems fall back to no optimization
- Symlink or external junction optimization — complexity not justified by user scenarios
- Producer lease optimization — separate concern, not blocking this performance work

**Explicitly deferred to future work:**
- Policy v6 schema (if needed) — v5 is sufficient for this optimization
- Metrics dashboard or visualization — evidence JSON is sufficient for now
- Automatic parallelism tuning based on disk type (SSD vs HDD) — manual configuration acceptable
- Integration with Codex Desktop progress UI — CLI evidence output is sufficient

**Will not do:**
- Remove crash safety or content authentication — these are non-negotiable security properties
- Skip identity verification to save time — would violate TOCTOU defense
- Use approximate hashes (CRC32, xxHash) — SHA-256 is the security contract
- Allow file-level parallelism — correctness risk too high

## Further Notes

**Risk Management**
- Phase 1 (hash reuse) is lowest risk: purely additive, no concurrency
- Phase 2 (batch) is medium risk: changes PowerShell control flow but still single-threaded
- Phase 3 (parallel) is highest risk: concurrency requires careful journal design
- Rollout plan: Phase 1 → 2 weeks production validation → Phase 2 → 2 weeks validation → Phase 3

**Performance Expectations**
- Best case (local NTFS SSD, many small files): 6x improvement
- Typical case (local NTFS HDD, mixed file sizes): 4x improvement
- Worst case (network drive, large files): 1.5x improvement (batch only, no hash reuse or parallel)

**Compatibility Matrix**（设计预期，不是已测生产倍率；已测数字见「操作者指南」）
| File System | Hash Reuse | Parallel | Expected Gain |
|-------------|------------|----------|---------------|
| Local NTFS  | ✅         | ✅       | 6x            |
| Local ReFS  | ✅         | ✅       | 6x            |
| Local FAT32 | ❌         | ⚠️       | 2x            |
| Network     | ❌         | ❌       | 1.5x          |
| Removable   | ❌         | ❌       | 1.5x          |

**Acceptance Criteria for Production**
- All P0/P1 defects from adversarial review fixed
- Performance benchmark shows ≥4x improvement on 10k file test case
- Crash recovery tests pass with uncertain state handling
- Journal overhead <10% of total time
- File system detection works correctly on NTFS/ReFS/FAT32/Network
- Zero regressions in existing safety tests
- Documentation updated (user guide, troubleshooting)

**Timeline**
- Week 1 (Day 1-5): FILE_ID_INFO + hash reuse implementation
- Week 2 (Day 6-10): Batch processing optimization
- Week 3 (Day 11-15): Parallelization + complete testing
- Week 4 (Day 16-20): Production validation + documentation
- Total: 4 weeks from kickoff to production-ready

**Dependencies**
- Policy v5 activation (if not already done) — minimal, schema already defined
- Windows 8+ for FILE_ID_INFO — acceptable, Windows 7 users get conservative fallback
- PowerShell 7+ — already required by Codex environment
- No external library dependencies — pure .NET Framework/PowerShell

**Success Metrics**
- Primary: User-reported deletion time reduced from 60min to <15min
- Secondary: Hash read amplification reduced from 7x to 4-5x
- Tertiary: Journal overhead measured at <10% of total time
- Qualitative: Zero P0 bugs reported in first month of production use
