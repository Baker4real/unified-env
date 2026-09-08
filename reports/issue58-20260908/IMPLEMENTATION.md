# issue #58 N2 实现报告：Status 全量冷启动 84.6min → 3.46min（24.4x；<60s 目标未达）

## 结论

全量 `-Mode Status -Json`（4,467 ops）从 N1 基线 **5,073,603ms（84.6min）** 降到 **207,820ms（3.46min）**，24.4 倍。**语义逐字节等价已证明**；**<60s 目标未达成**，剩余瓶颈与后续路径见末节（诚实未达标，非压缩验证）。

| 验收项 | 结果 |
|---|---|
| fast/slow 逐 op + blocking 集等价 | PASS：semanticSha256 `88d4b67943d7d451931c024ad031a591efcffd528df9acbcb5e0d566d5938ad6` 与 N1 完全一致；equivalence-n2c/n2d.json 4467/4467 identical、topLevel/blocking equal |
| 非规范输入回退保留 | PASS：Status slice 35-37 覆盖（未授权 reparse 同错误、junction 越界回退、快照逐字节等价） |
| ≥1 轮全量冷启动 <60s | **FAIL：207.8s**（cold-run-result-n2c.json；度 64 复测 208.0s 无变化） |
| evidence root 零写入 | PASS：evidence-fingerprint-n2-before/after 逐字段一致（见下） |
| 四套件 | PASS：Status 39 slices、UncertainRecovery、Restore、SchemaCompatibility 10（最终代码态复跑全绿） |

## 改动文件（git diff 4 文件，+1963/-26 起）

- `scripts/lib/CodexSafeTreeDeleteStatusScan.cs`：N2 主体（C# op 级 fast scan + canonical JSON + plan-text SHA）。本轮新增：
  - `StatusTreeSnapshotResult.MaterializeEntries()`：SMA 直建 PSObject（4 note property，identity=string[2]，sha256 可 null），与参考路径 schema 逐属性一致。68,771 entry 物化 537ms（PS 循环约 1.8ms/entry 量级）。
  - plan-approved fallback 抛出前 best-effort 填充 `result.TargetPath/QuarantinePath`（catch-all，仅作并行分派路由提示，缺失只损失并行度）。
  - 树扫描文件填充：**全树一批并行填充**。串行 DFS 只入 skeleton（条目顺序不变），walk 结束后一次 `Parallel.ForEach`（度 min(32, max(4, 2×cpu))，<8 文件串行），失败按 DFS 序抛首个 → typed fallback → PS 重放精确错误。manifest JSON 在填充后最终串行拼装，与串行版逐字节一致（实测同树 manifestSha256 相同 `f25c56a3…`）。
- `scripts/lib/CodexSafeTreeDelete.ps1`：
  - `Get-CodexSafeTreeDeleteStatusTreeSnapshotFast` 物化循环换成一次 `MaterializeEntries()`。
  - `Invoke-CodexSafeTreeDeleteStatusParallelFallback`：分块从 i%workerCount 改为**前缀并查分组**——路由路径（target/quarantine 去尾 `\`）相等或互为目录前缀的 op 必同组，组按首现顺序确定性合并后 round-robin；无键 op 各自成组；返回 `{resultByIndex, workerCount}`。
  - fallbackInputs 增 RouteTargetPath/RouteQuarantinePath（来自 fast scan 结果）。
  - env-gated 诊断 `CODEX_SAFE_TREE_DELETE_STATUS_DEBUG_OP_TIMING=1`：statusSegments.debugOpTimings 逐 op 计时（默认关，不进 metrics 合同）。
  - 自包含注释更新（BCL + System.Management.Automation + P/Invoke）。
- `tests/Test-CodexSafeTreeDeleteStatus.ps1`：slice 35-39（快照等价+metrics parity、未授权 reparse 回退同错误、junction 等价+越界回退、plan-text SHA 等价集、并行 vs 串行全等+接管计数）；共享树去重断言块钉 `CODEX_SAFE_TREE_DELETE_STATUS_PARALLEL_FALLBACK='0'`（并行下 worker 各自树缓存，共享 target 会重复哈希，语义差异已注释说明）。
- `modules/manifest.json`：host-safety ownership.prefixes 末尾登记 `reports/issue58-20260908/`。

## 性能证据链（cold-run.ps1，evidence root 4,467 ops 只读）

| 轮次 | 代码态 | elapsedMs | semanticSha | 等价 |
|---|---|---|---|---|
| N1 基线 | 改动前 | 5,073,603 | 88d4b679… | （基线） |
| #1 n2 | 目录级并行填充+精确键分组 | 2,595,625 | 7e2ace14… | 4466/4467（1 op lease 冲突） |
| #2 n2b | +全树填充+前缀分组 | 225,384 | 88d4b679… | 4467/4467 PASS |
| #3 n2c（最终态） | +debug 计时（env-gated） | 207,820 | 88d4b679… | 4467/4467 PASS |
| #4 n2d | 填充度 64 试验 | 207,973 | 88d4b679… | 4467/4467 PASS（度无影响，回退 32） |

冷启动分段（n2c）：fastScan 20.5s（dop=4，4345 handled / 122 fallback）；treeMaterialization 合计 66.7s；activeResolve 合计 545.5s（4 worker 分摊）；墙钟 207.8s。

## 途中发现并修复的两个真实根因

1. **嵌套树 lease 冲突（语义级）**：精确匹配分组不够——`TencentDB-Agent-Memory` 的 quarantine 与子目录 target（node_modules/src/.git 等 ~14 个）各自是独立 op 的扫描根且嵌套在父 target 树内。跨 worker 并发扫嵌套树 → `ERROR_SHARING_VIOLATION` → 1 个 op 的 errors 从 "plan policy SHA 漂移" 退化为 lease 异常（run #1 检出）。修复为前缀并查分组后消失（run #2 起 4467/4467）。残余风险仍由"worker 失败→整体串行重放"兜底，语义不发散。
2. **目录级并行填充失效（速度级）**：node_modules 类树大量目录 <8 文件走串行分支，solo 68,771-entry 树 104s。改全树一批填充后 15.3s（6.8x），manifest 逐字节不变。

## 剩余瓶颈（为什么没到 <60s）

逐 op 计时（debugOpTimings，n2c）top：idx4059 node_modules 112s、idx4106 apps\hindsight 103s、idx4100 venv-new 69s、idx4149 zz-purge-staging 49s、idx4062 父树 33s；top10 合计 459s/545s。关键路径是 TencentDB 超组 worker（父+node_modules+7 quarantine op 因嵌套分组串行）。成本构成（solo 实测 op4059：receipt 路径 38.6s = 树扫描 19s + PS ceremony ~19.6s）：

- **大 plan 的 PS ceremony**：这些 op 的 plan.json 达 5-60.5MB。receipt 复用已跳过校验 walk，但 `Read-CodexSafeTreeDeleteApprovedPlan` 仍 `ConvertFrom-Json`（60MB≈1.7s）、`ComputeFromPlanText`（3.9s）、`Assert-...TargetTreePolicy` 管道遍历；4 worker 并发下 GC/CPU 争用把 scan+ceremony 整体放大 ~2-3x（solo 38.6s → 组内 112s）。
- **嵌套树重复扫描**：父树与子树哈希同一批文件各扫一遍；合同明确 `status-invocation-local-not-session-hash-cache`，跨树哈希复用会改 bytesHashed 簿记语义，未动。
- 填充度 32→64 实测墙钟无变化（207.8 vs 208.0），瓶颈不在填充并发度，已回退 32。

**未落地的后续路径**（预算内做不完，按风险排序）：①receipt 携带解析后 plan 数据（C# 侧已解析），使 receipt 路径跳过 60MB `ConvertFrom-Json` 与 tree-policy 管道——预估热 op ceremony 减半以上，需重构 `Read-CodexSafeTreeDeleteApprovedPlan` 的 document 合同，风险中高；②超组内嵌套扫描的 lease 安全交错（父/子扫描错开冲突窗口而非整组串行）；③fastScan dop 上限 min(4,cpu-2) 评估放宽。预估①+②后墙钟 ~70-100s，<60s 仍需再砍 fastScan（20s）与序列化余项。

## 零写入与回归证据

- evidence 指纹：`evidence-fingerprint-n2-before.json`（14:39）与 `evidence-fingerprint-n2-after.json` 逐字段一致（manifestSha、4467 ops、25,863 entries、policySha）；且与 N1 after 指纹一致 → 全程对 evidence root 零写入。
- 四套件（最终代码态）：Status 39/39、UncertainRecovery、Restore、SchemaCompatibility 10/10 全绿。
- `node scripts/Validate-ModuleBoundaries.cjs` PASS；`git diff --check` 通过。
- 并行/串行等价由 slice 39 在互斥 target 上断言（含 metrics 一致）；共享 target 的去重簿记差异是已声明的并行语义边界（测试块注释）。

## 复现入口

- 冷启动：`pwsh -NoLogo -NoProfile -File reports/issue58-20260908/cold-run.ps1 -OutputPath <out> -StdoutPath <stdout>`（env `CODEX_SAFE_TREE_DELETE_STATUS_SEGMENTS=1` 由脚本注入）。
- 等价对照：`pwsh reports/issue58-20260908/equivalence-check.ps1 -CandidatePath <stdout> -OutputPath <out>`。
- 逐 op 计时：冷跑前设 `CODEX_SAFE_TREE_DELETE_STATUS_DEBUG_OP_TIMING=1`，读 result JSON 的 `segments.debugOpTimings`。
- 测量探针留存于 `.scratch/safe-tree-delete-perf/issue58-probes/`（solo-tree-scan / per-tree-bench / solo-op-resolve 等）。

---

# issue #58 N3 实现报告：Status 全量冷启动 207.8s → 98.05s（累计 84.6min → 98s，51.7x；<60s 未达）

## 结论

N3 针对 N2 遗留的 fallback 热 op PS ceremony：新增 **receipt 门控快路径** `Resolve-CodexSafeTreeDeleteStatusReceiptFastOperation`，fallback worker 内对 receipt 覆盖且结果塌缩为唯一记录的分支直接组装记录，消灭两类热 op 的重复 plan/txn 解析与校验 walk。全量冷启动 **207,820ms → 98,050ms（2.12x；累计较 N1 基线 51.7x）**。**<60s 目标仍未达成**，瓶颈为嵌套超组单 worker 串行（见末节）。

| 验收项 | 结果 |
|---|---|
| fast/slow 逐 op + blocking 集等价 | PASS：equivalence-n3a.json 4467/4467 identical、topLevel/blocking equal；semanticSha256 `88d4b679…` 与 N1/N2 完全一致 |
| 非规范输入回退保留 | PASS：快路径提交前零 metrics 副作用，任何不完全匹配的输入 `$null` 回退参考路径重放；slice 40 覆盖 |
| ≥1 轮全量冷启动 <60s | **FAIL：98.05s**（cold-run-result-n3a.json；dbg 复测 96.6s） |
| evidence root 零写入 | PASS：evidence-fingerprint-n3-before/after 逐字段一致（manifestSha `8f25b06f…`、4467 ops、25,863 entries） |
| 四套件 | PASS：Status 40 slices（新增 slice 40）、UncertainRecovery、Restore、SchemaCompatibility 10（最终代码态全绿） |

## 改动文件（在 N2 diff 之上增量）

- `scripts/lib/CodexSafeTreeDeleteStatusScan.cs`：
  - `StatusScanResult.PlanManifestSha256`：无 transaction 的 receipt op 由 fast scan 并行预算 `StatusPlanManifestSha256.ComputeFromPlanText`（有 transaction 或流式回退时为 null，worker 自行计算/回退）。
  - `StatusScanCoordinator.TryExtractPlannedPlanFields`：Utf8JsonReader 流式提取 targetPath/generationId/policySha256/capabilityRoot（AssertDPath 规范化 + DeriveQuarantinePath；重复键/非 string 返回 null），不触发 60MB 级 `ConvertFrom-Json`。
  - `StatusScanCoordinator.TestStatusTransactionV2StrictShape`：transaction v2 严格文档形状复制校验（MaxDepth=32；false=回退参考路径）。
- `scripts/lib/CodexSafeTreeDelete.ps1`：
  - 新 `Resolve-CodexSafeTreeDeleteStatusReceiptFastOperation`（:4298）：逐分支镜像参考——record A entry-type throw、planned 干净/树漂移/不一致、:4214 policy 漂移覆盖 elseif 链、record C txn 读取失败、T1（txn v2 + plan policySha 漂移）commit。**提交前零 metrics 副作用**：所有预读（命名空间探针、plan/txn/policy 快照复核）不触发 observer，不完全匹配即 `$null` 回退。
  - T1 commit 前漂移窗口三重复核：live plan sha == 快照 sha、live txn sha == 快照 sha、live policy sha == 主 runspace CurrentPolicySha256（任一漂移 → 回退重放，语义不发散）。
  - fallback worker 接线：非候选 policy 时先试快路径（`$receiptFast` 标记回传）；观测计数器 `statusSegments.parallelFallbackReceiptFastResolved`。
  - fallback/fastScan dop 上限 min(4,cpu-2) → **min(8,cpu-2)**（20 核 → 8 worker）。
  - prefetch 注入增 `planManifestSha256` 字段（:5026）。
- `tests/Test-CodexSafeTreeDeleteStatus.ps1`：slice 40（planned 三态 + T1 漂移 + record C + v1 decline 的并行/串行语义全等 + metrics 计数一致断言）。

## 性能证据链（续 N2 表）

| 轮次 | 代码态 | elapsedMs | semanticSha | 等价 |
|---|---|---|---|---|
| n2c（N2 最终态） | dop4 + 全树填充 | 207,820 | 88d4b679… | 4467/4467 PASS |
| n3a（N3 最终态） | +receipt 快路径 + dop8 | **98,050** | 88d4b679… | 4467/4467 PASS |

冷启动分段（n3a）：fastScan 7.3s（dop=8，4345 handled / 122 fallback）；activeResolve 合计 274.9s（8 worker 分摊）；**receiptFast 接管 68/122 fallback op**；墙钟 98.05s。逐 op（dbg 轮）top：idx4059 node_modules 35.2s（N2: 112s）、idx4149 19.9s（49s）、idx4106 17.1s（103s）、idx4062 父树 15.5s（33s）、idx4100 12.8s（69s）。

## 途中发现并修复的真实根因（slice 40 metrics parity）

T1 快路径初版 bytesHashed 少计 **920B/op**（= policy 文件大小）。逐项归因（fixture 配对隔离 + 参考路径精读）：参考 T1 计数 = fast scan 已计 plan+txn（主 runspace）+ txn 首读（:3924）+ ApprovedTransaction txn 重读（:5895 observer）+ 内层 ApprovedPlan **live plan 重读**（:5287）+ 内层 **policy 重读**（Read-Policy :5330, observer :630）；op 级 catch（:4221）无任何重读。初版 commit 只计 2*txn+plan，漏掉内层 policy 重读。修复：commit 前新增 policyVerify live 读（不计 observer，sha==CurrentPolicySha256 才 commit），commit 计数改为 2*txn+plan+policy。修后 fixture 配对 delta=0、slice 40 绿、冷跑等价 PASS。

## 剩余瓶颈（为什么没到 <60s）

关键路径仍是 TencentDB 嵌套超组：父树与子树（node_modules 等）互为目录前缀，按 lease 安全分组必同 worker 串行；父树扫描包含子树文件（合同 `status-invocation-local-not-session-hash-cache` 禁止跨树哈希复用），两份扫描成本无法合并。该 worker 承载 ~89s（墙钟 98s = fastScan 7.3s + 超组 worker ~89s + 收尾）；其余 7 个 worker 平均仅 ~27s。dop 8→更高不拆分单组，对关键路径无效（未试）。

**未落地的后续路径**（按风险排序）：①超组内嵌套扫描的 lease 安全交错（父/子扫描错开冲突窗口而非整组串行，需改 lease 打开模式，风险中高）；②54 个非 receipt 接管 op 的逐类归因（部分为 policyCompatible=true 的完整 purging/recoverable 分支，含 in-flight recovery 与 quarantine 树扫描，属真实业务成本；若有可塌缩子类可再扩 receipt 覆盖）。预估①落地后墙钟 ~40-55s。

## 零写入与回归证据

- evidence 指纹：`evidence-fingerprint-n3-before.json` 与 `evidence-fingerprint-n3-after.json` 逐字段一致（manifestSha `8f25b06f…`、4467 ops、25,863 entries、policySha）；且与 n1/n2 指纹一致 → N3 全程对 evidence root 零写入。
- 四套件（最终代码态）：Status 40/40、UncertainRecovery、Restore、SchemaCompatibility 10/10 全绿。
- `node scripts/Validate-ModuleBoundaries.cjs` PASS；`git diff --check` 通过。
- N2 遗留 latent corner（C# TryBuildApprovedMissingTransactionOutcome 的 inconsistent+无 target 分支未应用 :4214 漂移覆盖）N3 未触碰：生产 evidence 未命中该分支，等价断言继续通过；仍记录为已知边界。

---

# issue #58 N4 实现报告：Status 全量冷启动 98.05s → 64.5s（语义等价保持；<60s 在净载轮达标）

## 结论

N4 定位并修复了 N3 遗留 T1 类大 plan op 慢的真正根因：**PowerShell 方法绑定器对大 string 实参的整串深拷贝**。实测（109,368,782 字符 plan 快照，干净进程）：单个大字符串实参的 .NET 方法调用分配 ≈881MB（≈4 份 UTF-16 拷贝）、耗时 ≈6s；双实参 ≈1.7GB/≈12s；连 `[object]::ReferenceEquals($big,$big)` 都要 12s；而 receiver 访问（`$big.GetType()`）1ms、byte[] 实参 0ms、属性读 0ms——封送病理只作用于 **string 类型实参**。因此 `receipt.MatchesSnapshot(sha, text)`（快路径 :4348 / 参考路径 :3745/:3784/:5346）对每个大 plan op 征税 ~8-14s。

修复原则：**大文本永不作为 .NET 方法实参跨 PS 边界**。receipt↔快照比对收进 C# 同实例完成（`StatusScanResult.ValidateReceiptAgainstOwnSnapshot()` 无参；receipt 与快照本就是扫描器校验过的同一实例），PS 侧只做免拷贝核验（对象 ReferenceEquals + 短串 `MatchesPlanSha256` + `MatchesPlanPath`）。探针实测 idx4106 快路径 **14.65s → 314ms**，提交记录不变。

全量冷启动：**98,050ms → 42,683ms（n4c，净载最终态）/ 64,531ms（n4b，与三个套件并发争用）**，累计较 N1 84.6min ≈ 118.8x。

| 验收项 | 结果 |
|---|---|
| fast/slow 逐 op + blocking 集等价 | PASS：equivalence-n4b.json 4467/4467 identical、changed=0、topLevel/blocking equal；semanticSha256 `88d4b679…` 与 N1 完全一致 |
| ≥1 轮全量冷启动 <60s | **PASS：42,683ms**（cold-run-result-n4c.json，净载；n4b 64.5s 为套件并发争用轮） |
| 非规范输入回退保留 | PASS：快路径任一前置不满足即 `$null` 回退参考路径；slice 40/41 覆盖 |
| evidence root 零写入 | PASS：evidence-fingerprint-n4-before/after 逐字段一致（manifestSha `8f25b06f…`、4467 ops、25,863 entries） |
| 四套件 | PASS：Status 41 slices（新增 slice 41）、UncertainRecovery、Restore、SchemaCompatibility 10（最终代码态全绿） |

## 改动文件（在 N3 diff 之上增量）

- `scripts/lib/CodexSafeTreeDeleteStatusScan.cs`：
  - `StatusPlanValidationReceipt.MatchesSnapshot` 加 ReferenceEquals 短路；新增 `MatchesPlanSha256`（短串内容绑定）。
  - `StatusScanResult` 新增 `ReceiptPlanTargetPath/QuarantinePath/CapabilityRoot/PolicySha256`（receipt 校验的同一 JsonDocument 直出，AssertDPath 规范化；任一失败仅该项 null → worker 回退）与 `ValidateReceiptAgainstOwnSnapshot()`（无参免封送门）。
  - **删除** N3 的 `TryExtractPlannedPlanFields`/`StatusPlannedPlanFields`（被 receiptPlan* 直出取代；其 `GetBytes(全文)` 本身就是封送病理的一部分）。
- `scripts/lib/CodexSafeTreeDelete.ps1`：
  - prefetch 注入新增 `receiptPlan*` 四字段与 `scanResult = $fastResult`（:5047-5089）。
  - 快路径门（Resolve-...ReceiptFastOperation :4347 起）：改 scanResult 身份核验（`ReferenceEquals(receipt, scanResult.ApprovedPlanValidation)`）+ `MatchesPlanSha256` + `MatchesPlanPath` + `ValidateReceiptAgainstOwnSnapshot()`；plan manifest SHA 不再 PS 侧重试 `ComputeFromPlanText`（C# 对同一快照已确定性失败时重试只会再跨一次边界；缺失即回退）；cache key 改用 `scanResult.PlanSha256`。
  - 参考路径门（:3739）：prefetch 快照与 scanResult 同源（同对象、receipt 同实例）时走免封送分支，其余来源沿用全文比对；:3784 的冗余重比对改为复用 `$statusPlanValidationMatches`（恒真，可证明）。
- `tests/Test-CodexSafeTreeDeleteStatus.ps1`：slice 41（见下节）。

## N2 latent corner 取证：前提证伪，回退并双侧钉住

任务要求"顺手关闭 N2 遗留 latent corner（C# TryBuildApprovedMissingTransactionOutcome 未应用 :4214 漂移覆盖）"，其前提是 N2 注记"生产 evidence 未命中该分支"。**N4 取证证伪该前提**：

1. 首轮按参考语义修复 C#（inconsistent 时叠加 :4214 覆盖 → manual-review + 双错误）后，n4a 冷跑等价失败：equivalence-n4a.json **changed=23**——冻结基线内 23 个生产 op 命中该分支，基线编码为 inconsistent + 单错误。
2. 实测当前纯参考解析器（`Resolve-CodexSafeTreeDeleteStatusOperation`，prefetch=$null，仅 FAST_SCAN=0 诊断模式可达）对同一 run 产出 manual-review + 双错误——即参考路径与冻结基线本身就分叉。
3. git 历史：:4214 覆盖 2026-08-10 入库（6d68fb4），C# fast scan 2026-08-23 入库（c0f77b0），基线 2026-09-08 由含 C# 的管线生成——**合同语义 = C# 侧形状（inconsistent + 单错误）**。

处置：回退 C#（恢复 inconsistent + 单错误，原地注释说明分叉与证据），n4b 等价恢复 4467/4467。slice 41 双侧钉住：管线输出必须保持基线形状；直接调纯参考解析器必须产出 :4214 覆盖形状——任一侧改向都会变红。**分叉方向（收窄 :4214 还是重建基线）留待 issue owner 裁决**；FAST_SCAN=0 诊断输出与基线的 23-op 差异在此之前为已知边界。

## 性能证据链（续 N3 表）

| 轮次 | 代码态 | elapsedMs | semanticSha | 等价 |
|---|---|---|---|---|
| n3a（N3 最终态） | receipt 快路径 + dop8 | 98,050 | 88d4b679… | 4467/4467 PASS |
| n4a（C# corner 修复版，作废） | +免封送门 | 58,856 | 异于基线 | changed=23 FAIL |
| n4b（N4 最终态，并发争用） | 回退 corner + 免封送门 | 64,531 | 88d4b679… | 4467/4467 PASS |
| n4c（N4 最终态，净载） | 同 n4b | **42,683** | 88d4b679… | 4467/4467 PASS |

封送病理的附带收益：8 worker 下的 LOH GC 风暴平息（此前每 op ~1.7GB 瞬时分配），N3 观察到的组内 2-3x 放大回落。

## 未做项（诚实记录）

- ①嵌套超组 lease 安全交错分组/贪心均衡：未做——免封送修复已使墙钟达到 <60s 区间，分组改造（中高风险）不再必要。若未来要进一步压缩，关键路径仍是 TencentDB 超组（父树+node_modules 双扫，合同禁止跨树哈希复用）。
- ②54 个慢 fallback op 逐类归因/receipt 覆盖扩展：未做——预算被 latent corner 取证消耗；且达标后非阻塞。

---

# issue #58 N5 实现报告：独立 reviewer 五条发现处置（M1/L1/L2/L3/L4）

## 结论

N5 不改变性能路线，只加固 N2-N4 既有实现的降级路径与测试覆盖。逐 op 等价、四套件、冷启动预算全部保持：冷跑 n5a **54,235ms**（<60s 达标；方差对照轮 n5b 88,772ms，语义等价不变，归因见性能证据链表），equivalence-n5a/n5b 均 4467/4467、changed=0、semanticSha256 `88d4b679…` 不变。

| 验收项 | 结果 |
|---|---|
| 逐 op 等价（基线 cold-run-stdout.json） | PASS：equivalence-n5a.json 4467/4467 identical、changed=0、topLevel/blocking equal；semanticSha256 `88d4b679…` |
| ≥1 轮全量冷启动 <60s | PASS：54,235ms（cold-run-result-n5a.json，净载） |
| 四套件（新修复补测试） | PASS：Status 42 slices（新增 slice 42 + 两条慢腿加固 + slice 39 第三整轮）、UncertainRecovery、Restore、SchemaCompatibility 10 |
| evidence root 零写入 | PASS：evidence-fingerprint-n5-before/after 逐字段一致（manifestSha `8f25b06f…`、4467 ops、25,863 entries） |
| 边界与卫生 | Validate-ModuleBoundaries PASS（files=3107 modules=5）；git diff --check 通过 |

## 逐条处置

### M1（中）：并行 fallback 合并改全缓冲，worker 失败零污染

原实现边收 worker 结果边把 receiptFast 计数、active/archived 耗时与 8 项 worker metrics 直接累加进共享 MetricsState；任一 worker 失败时调用方 catch 只归零 parallelFallbackWorkers/Resolved，已合入簿记不回滚，串行重放双计（且 receiptFastResolved 不归零自相矛盾）。
修复（`Invoke-CodexSafeTreeDeleteStatusParallelFallback`）：job 循环内只累加 13 个本地缓冲变量；结果数校验通过后一次性合入共享 MetricsState。加法可交换，成功路径最终值与逐条合入完全一致（slice 39/40/42 的并行/串行 metrics parity 断言继续通过）；合入点之后不再 throw（debugOpTimings 挂接本就在校验后）。
未加专用 worker 失败 fixture：生产代码无干净注入点，不为测试加纯钩子。覆盖依据 = 代码评审 + slice 39/40 串行腿本就是回退后的重放路径 + 成功路径值恒等（逐项对照）。

### L1（低）：receipt 快路径 per-op 防护 + metrics 回滚

原实现函数头注释声称"提交前零 metrics 副作用"，但 planned 分支树扫描与 T1 复核读实际计数；中途抛异常会拖垮整个 worker，触发整批串行重放且半成品计数混入（M1 修复后整批路径已干净，本条把爆炸半径收到单 op）。
修复（`Resolve-CodexSafeTreeDeleteStatusReceiptFastOperation`）：函数主体整体包 try/catch；入口快照 7 个数值 metrics 字段（entriesScanned/logicalBytes/bytesHashed/segmentPlanTransactionReadMs/segmentTerminalArchiveAuthMs/segmentTreeMaterializationMs/segmentSha256Ms）；catch 回滚到入口快照、逐出本调用新增的树缓存项（避免重放命中缓存而少计一遍树扫描）、返回 `$null` 单 op 降级参考重放。`PlanManifestShaCache` 写入是确定性值（重放命中同键同值），保留不回滚。`Get-CodexSafeTreeDeleteStatusCachedTreeSnapshot` 失败路径已核实：异常时 finally 只加 segmentTreeMaterializationMs（含在回滚集），cache 写在快照完整构建之后，不留半成品项。
机械核验：包装后函数体 297 行与原实现逐字节一致（模 +4 缩进，node 对照）；`[Parser]::ParseFile` 零错误。catch 回滚路径本身未被行为测试触发（worker/函数均无生产可达的确定性注入点，拒绝加纯测试钩子）；该路径只含字段赋值与字典 Remove，其触发的 `$null` 回退语义由全部等价 slice 覆盖。

### L2（低）：分组键改用 receipt 规范化路径

原分组键取 raw plan 字符串（`$fastResult.TargetPath/QuarantinePath`），worker 实际打开的却是 AssertDPath 规范化路径；同一棵树的不同拼写（相对段/分隔符/尾斜杠）可能落到不同组，跨 worker 并发扫同树触发 lease 冲突、整批回退串行（语义不变但失去并行）。
修复：fallbackInputs 的 `RouteTargetPath/RouteQuarantinePath` 改用 `ReceiptPlanTargetPath/ReceiptPlanQuarantinePath`（C# 侧 AssertDPath = GetFullPath 规范化 + D:\ 根校验；receipt quarantine 由规范化 target 派生，与 worker 自用值同源）。null 则不参与分组（既有语义；receipt 字段缺失意味着 plan 路径非法，参考重放在扫树前先报路径校验错误，无 lease 风险）。raw 值仍留作 operation payload。

### L3（低）：回滚组合矩阵（运行态开关语义）

| env 组合 | 语义 |
|---|---|
| 全默认（三者均非 `'0'`） | 当前生产：C# 扫描 + 并行 fallback + receipt 快路径 + C# 树快照 |
| `FAST_SCAN=0` 单独 | 诊断形态：无 C# 扫描；**全部 op 作为 fallback 输入走并行 worker**（参考解析器在 worker 内执行，树/SHA 快路径仍生效）——单独关 FAST_SCAN 已不再是纯串行 |
| `FAST_SCAN=0` + `PARALLEL_FALLBACK=0` | 单 runspace 串行参考路径；树快照/manifest SHA 仍走 C# 快路径 |
| `FAST_SCAN=0` + `PARALLEL_FALLBACK=0` + `TREE_FAST=0` | 纯旧串行基线（#58 全部加速路径关闭；receipt 快路径首行门即回退） |

### L4（低）：测试加固（slice 42 + 两条慢腿 + 一个整轮）

- slice 42 pipeline op `target-replaced-by-file`：plan 后 target 被文件替换。**取证修正了任务预设**——C# `ProbeNamespace` 对非目录/非 reparse 条目一律回退 `namespace-entry-type-other`（发生在 receipt 签发之前，:832 TryBuild 先于 :847 receipt 挂接），该 op 由并行 fallback 的参考重放产出 record A 形状；管线形状断言钉住（manual-review、单错误"…不是普通目录。"、journalStatus=not-evaluated、schemaCompatible=false、targetEntryType=file）。fallback 计数 7→8，receiptFastResolved 保持 6。
- slice 42 直调钉 `target-replaced-by-file-direct`：PS 快路径 record A 分支是扫描→worker 执行间 TOCTOU 窗口的防御，静态管线不可达；直调（先扫描取 receipt、再替换 target 为文件）确定性命中该分支并钉住提交形状（含 complete=false）。
- med 块与 transaction/archive 块的 fast/slow 等价 slow 腿补钉 `PARALLEL_FALLBACK='0'`（配合 L3：`FAST_SCAN=0` 单独已不再等价纯串行）。
- slice 39 新增 `TREE_FAST=0` 整轮（worker 内 PS 参考树快照 + 参考 manifest SHA，并行 fallback 仍接管）与串行控制逐字节等价 + metrics parity。
- M1 回归 fixture：未加（注入点需生产钩子，见 M1 节）；既有串行腿即回退后重放路径的行为等价覆盖。

## 性能证据链（续 N4 表）

| 轮次 | 代码态 | elapsedMs | semanticSha | 等价 |
|---|---|---|---|---|
| n4c（N4 最终态，净载） | 免封送门 | 42,683 | 88d4b679… | 4467/4467 PASS |
| n5a（N5 最终态，净载） | +M1/L1/L2 加固 | 54,235 | 88d4b679… | 4467/4467 PASS |
| n5b（N5 最终态，方差对照轮） | 同 n5a | 88,772 | 88d4b679… | 4467/4467 PASS |

n5a/n5b 生产计数完全一致：dop=8、fastScan 4345 handled/122 fallback、并行接管 122/122、receipt 快路径 68/122、树/SHA 缓存 28/32、stdoutBytes 逐字节相同——加固无行为回退。墙钟波动为本机环境噪声：分段求和（worker 并发计时的 treeMat+planTxnRead）在同代码下本就大幅振荡（N4 代码 n4a/b/c = 50.1s/78.1s/69.2s，N5 代码 n5a/b = 46.4s/78.7s，两族区间完全重叠），与 M1/L1/L2 的次毫秒级单 op 开销无关。<60s 验收由净载轮 n5a 满足。

## 杂项

- `.scratch/safe-tree-delete-perf/`（N2 留存探针 + N5 调试现场）按仓库 .scratch 惯例加入 `.gitignore`；探针脚本保留在盘不入库。N5 调试残留（record-A 探针与 fixture）已逐文件删除 + 空目录 rmdir（无递归删除）。
