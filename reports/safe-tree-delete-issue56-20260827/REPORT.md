# safe-tree-delete #56 Wave A 实施证据（2026-08-27/28）

实施依据：`docs/plans/2026-08-27-safe-tree-delete-issue56-implementation.md`（最新落盘版：多轮 fresh-reviewer/verifier 闭环定稿）。
AC 口径预注册（更正版，取代已作废的首条双口径评论）：https://github.com/Baker4real/unified-env/issues/56#issuecomment-5447433839

## 交付物（对齐最新版计划 §4/§5/§9）

**§4.1 walker 与 seam**
- `scripts/lib/CodexSafeTreeDeletePlanSnapshot.cs`：单遍 `PlanTreeSnapshotBuilder`。file leaf 以 safe lease 为权威线性化点：lease 后先捕获 baseline {FileIdentityV2 稳定字段+streamNames+hardLinkCount} → `after-file-baseline-captured-before-hash` checkpoint → `ComputeSha256FromHandle()`（保留句柄复验）→ 同句柄重捕获逐项比对（capturedAtUtc 之外漂移即 throw）。directory/'.' root 走 `VerifiedDirectoryChainGuard.CaptureSafeTreeDeleteDirectoryStreamSet()`（assembly-internal DTO、自包含 FILE_STREAM_INFORMATION 解析、pre/post identity/link 对比）。junction 保留 per-path 重开（reparse sha 走 `ReparseDataSha256`）。稳定 OrderBy+CurrentCultureIgnoreCase。`Build` 无测试 hook；`BuildForTest(checkpoint)` 提供 `after-entry-observed-before-open` / `after-file-baseline-captured-before-hash` 双 checkpoint，异常不吞。
- `scripts/lib/CodexHookHandleBoundIO.cs`：prefactor 后恢复 BCL-only（`HostSafetyParallelPurge*` adapter 原样移出至 `scripts/lib/CodexSafeTreeDeleteHostSafetyPurgeAdapter.cs`），支持 standalone Add-Type。
- `scripts/lib/CodexSafeTreeDelete.ps1`：`Get-CodexSafeTreeDeletePlanTreeSnapshot` wrapper（前置校验全套、.NET 异常解包、checkpoint 透传）；`New-CodexSafeTreeDeletePlan*FromCaptures` 派生器（fail-closed 消息与 PS 三遍逐字对齐）；`New-CodexSafeTreeDeletePlan` 双模式接线（`-DisablePlanCSharpWalkerForTest`、`-PlanWalkerCheckpointForTest`、分段计时 stash）。同时修复一处既有潜在缺陷：Apply/Purge 在禁用哈希复用的全新进程里读取未设的 `$script:CodexSafeTreeDeleteLastStreamCaptures` 会 StrictMode 崩溃（读取处加存在性守卫，null 走逐 leaf 复验）。

**§4.3 native loader**
- `scripts/lib/CodexHostSafetyNativeLoader.ps1`：唯一 source 选择/digest/编译/发布/加载实现。env `CODEX_SAFE_TREE_DELETE_PLAN_CSHARP_WALKER=0` 在任何 PlanSnapshot source 读取前判定 → base source 集（不含 PlanSnapshot）；默认 base+PlanSnapshot。内容寻址 generation `<root>/<variant>/<compositeSha>/`（composite 绑定 variant+有序 source SHA+contract version+PS/.NET/OS/arch+编译选项）；deny-write（FileShare.Read）句柄读取+staging 编译；`Assembly.Load(byte[])`（verify 后不按 path 重开）；no-replace rename 发布；进程 registry 与转移（default→base 只切行为；base→default throw `fresh-process-required`；幂等）。fixture 编译 seam（进程内 capability）与 generation inventory 助手。两份 PS loader 只声明调用。

**§9 部署子系统**
- `scripts/invoke-codex-safe-tree-delete-gate-shim.ps1`：gate-aware shim（mutex+marker，持锁到退出）。
- `scripts/Deploy-CodexSafeTreeDelete.ps1`：唯一部署 owner（`BootstrapGate|Deploy|RecoverRollback`；create-only intent/SHA 链 phase-journal/invocation receipts/final-receipt；四字段 marker；marker-presence 矩阵；legacy drain（可执行+PID+命令行枚举，两次稳定零清单）；source switch=live closure 认证；validation=新 walker 小树 Plan；测试 seam 仅显式传参）。
- `scripts/lib/CodexSafeTreeDeleteClosure.ps1`：§7.2/§9 共用 source closure（固定闭包集+tests 发现，{path,length,sha256} 折叠）。
- `tests/Test-CodexSafeTreeDeleteDeployment.ps1`：9 场景部署矩阵（happy path、崩溃@10/30/60/70→Recover、marker/intent/journal 篡改拒绝、同 id/新 id 接管拒绝、complete 幂等收尾两分支、gate 外部持锁与 marker 在场负控）——全绿。

**§5 测试面**
- `tests/Test-CodexSafeTreeDeletePlanWalkerEquivalence.ps1`：保序逐位等价+词法断言+metrics 等值+junction/hardlink/目录 ADS 记录放行+Unicode 平局（U+212A）+负路径（lease 层 ADS、未授权 reparse 逐字一致、policy 前置层）+开关/env 路由（对套件级 env 预设密封化）+guard seam 差分（与 per-path 捕获同值、ADS ordinal）+kind 漂移 checkpoint 拒绝+lease 阻断 write/rename/ADS/hardlink+checkpoint 异常不吞+同 kind 替换正例。
- `tests/Test-CodexSafeTreeDeleteFileSystem.ps1`：结构化 skip 元数据（processId/processStartTimeUtc/isElevatedProcess/nativeFatFamilyDriveCount/skipReason/waiverIssue；唯一允许 tuple=非提权且无原生 FAT 族→waiver 35）。
- `tests/Test-CodexSafeTreeDeletePhase3Integration.ps1`：历史 leftover 降为 `historicalLeftoverObservation=present|absent` 观察，不构成 Gate 条件。
- manifest：新文件全部登记 ownership；新 profiles `host-safety/fixture-base`（28，=fixture 减等价性套件）与 `codex-host/handle-consumers`（directory guard+catalog guard 三件套+vendor-abort stress）。

**§3.1/§8 外发与文档**
- 预注册更正评论（单一判定协议：AC1=3 attempt 原值 max≤40000；AC2 typical DOP2 max≥4x、best 从 {DOP2,DOP4} 按 (max,median,DOP) 唯一选出≥6x、分母固定 576238ms；AC3=3 个 DOP2 attempt 全部 <10.000 不设 cap；退出码 0/2/3/1；不允许排除/替换/重试）。
- `docs/specs/2026-07-24-safe-tree-delete-capability.md` 新增「部署门与维护窗口」章节；性能 spec L448/L451 non-goal 修订、L6/L29 状态行、3/6→2/6 勘误三处；`ERRATA-20260827.md`（独立 dated errata，原始 JSON 未动，附 provenance SHA）。

**§7 评估器**
- `Invoke-Issue56FormalBenchmark.ps1`：固定 schedule（baseline-pre→AC1×3→DOP2/DOP4 交错×3→baseline-post）+ attempt ledger（create-only started/terminal、UUID/sequence 配对、fresh pwsh 子进程、walkerKind 实测回报、closure 前后校验、baseline ±10% sanity）+ 评估器（未取整原值判定、BENCH_PASS/FAIL/INVALID、退出码 0/2/3/1）。
- `Invoke-Issue56CloseGate.ps1`：G8 pre-close（BENCH_PASS+回归矩阵+evidence-index 生成回读→仅输出 READY_TO_CLOSE）/post-close（closed state+结论评论绑定 citedCommit 与 index SHA+时间序→COMPLETE）。

## §4.4 序列化 spike（spike/spike-summary.json）

serialize 探针 457/583ms（7.36MB ConvertTo-Json -Depth 100）、readback 7/6ms——远低于 4–8s 决策门，C# 序列化不触发。

## 正式基准轮（formal-round-*）

- `formal-round-20260828T015550Z`：**INVALID**（宿主会话中断杀掉 runner+子进程，attempt 01 started-无-terminal 孤儿；保留为 invalid，见其 INVALID.json）。
- `formal-round-20260828T021558Z`：11/11 attempt 有效（walkerKind 全部正确、exit 0），**BENCH_INVALID（exit 3）**：baseline-pre 745207ms（+29.3%）、baseline-post 966023ms（+67.6%）均击穿 576238ms ±10% 环境锚——当日磁盘仍被交互负载压慢，按协议不作 AC 结论、不换分母。候补参考（非判定）：AC1 max=11231ms；typical DOP2 max=81085ms≈7.11×；best=DOP4 max=78695ms≈7.32×。
- **正式验收待安静窗口重跑**：`pwsh -NoProfile -File reports\safe-tree-delete-issue56-20260827\Invoke-Issue56FormalBenchmark.ps1`（自动新 round 目录，完整 schedule）。

## 回归矩阵（regression-20260828-*.log）——全绿

| Profile | env | 结果 |
| --- | --- | --- |
| host-safety `fixture`（29 套件，含新部署测试与等价性） | 默认（csharp） | **OK** |
| host-safety `fixture-base`（28 套件） | `CODEX_SAFE_TREE_DELETE_PLAN_CSHARP_WALKER=0`（PS 三遍 + base variant） | **OK** |
| host-safety `host-live`（ProductionSmoke + Phase3Production） | 默认 | **OK** |
| host-safety `host-live` | env=0 | **OK** |
| codex-host `handle-consumers`（directory guard + catalog guard 三件套 + vendor-abort stress） | 默认 | **OK**（HandleBoundIO BCL-only 化的消费面验证） |

fixture #35 waiver 沿用（FileSystem 结构化 skip tuple：非提权且无原生 FAT 族 → `skipped-non-elevated`，`waiverIssue=35`）。矩阵执行中修复两处测试密封化缺口（等价性/部署测试未隔离套件级 env 预设），均为测试设计问题，非实现缺陷。

## 观测性差异记录

单遍 vs 三遍的跨遍漂移观察由 walker 内双观察（枚举属性 vs 句柄）+ lease pre/post 比对替代；directory 走 guard 同句柄 seam（CapturedKind 由 VerifyDirectoryHandle 认证推导），junction 走 per-path 重开——三者观察边界已记录于 capability spec 与 plan §8。guard 目录句柄（FileShare.Read）与 junction per-path（ReadWrite|Delete）的 share 模式差异在"并发写者已持句柄"极端时序下打开成败不同，与原 PS 第三遍一致。

## 回滚

plan.json schema 不变，新旧 producer 产物可互换；env=0 运行时回退（base generation 不读 PlanSnapshot source）；§9 部署子系统提供 shim cutover/marker/drain/RecoverRollback 全矩阵（测试全绿）。**生产 BootstrapGate/Deploy 执行、commit/push、结论评论与关票均待用户分别授权。**

## 终态（2026-08-28 收口）

- **发布**：实现与证据以 commit `fc73c05` 推送到 main（bulky run evidence 外置 `D:gentsun-evidence\safe-tree-delete\issue56-formal\`，原位指针+SHA）。
- **生产**：deployment `wave-a-20260828` BootstrapGate→Deploy complete；生产入口（cmd→gate shim→repo entry）live 冒烟通过；回退=env `CODEX_SAFE_TREE_DELETE_PLAN_CSHARP_WALKER=0`（fresh process）。
- **正式认证**：未完成。三轮 formal-round 全部 BENCH_INVALID（会话中断×1、baseline 锚点 +29%/+68%/+110%×2），维护者决定不再安排安静窗口重跑。
- **关票**：#56 于 2026-08-28T08:57:50Z 关闭，结论评论 issuecomment-5450518070（如实记录达成/未达成；G8 pre-close 保持 NOT_READY，关闭属维护者决定路径）。
- **重跑入口**（如需正式认证）：`pwsh -NoProfile -File reports\safe-tree-delete-issue56-20260827\Invoke-Issue56FormalBenchmark.ps1`，退出码 0 后走 `Invoke-Issue56CloseGate.ps1`。
