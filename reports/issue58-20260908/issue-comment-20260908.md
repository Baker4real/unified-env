## 阶段性现状记录（2026-09-08，subagent 编排推进轮）

本轮按 subagent-orchestration 推进：调查 → 实现（四轮）→ 独立只读评审 → 独立验收。**未 commit、未 push、未部署，本票保持 OPEN**；全部改动在工作区未提交（基线 HEAD 已为 `4df4f65`，本票改动为其上的工作区脏改 + 未跟踪证据目录 `reports/issue58-20260908/`）。

### 基线重测（修正既往认知）

- 首次测出当前真实全量冷启动全程：**5,073,603ms（84.6 分钟）**，4467 ops，exit 0。09-06 的 60,555ms 是 deadline kill 截断值，并非近似达标；真实全程此前从未测出。
- 主导热点：`scripts/lib/CodexHostSafety.ps1:884-887` 树快照递归内逐 child `Assert-CodexHookCapabilityPath`（实测占快照 74-81%，10.8-13.7ms/entry，O(entries×depth)）；快照段占总时 96.37%。
- 修正 09-07 结论：SHA-256 内容哈希与 identity 获取不是瓶颈（实测 1.4-1.6GB/s，全部 live tree 共 ~4s）；15 个 purging + 2 个 quarantined op 因 policyPath 漂移在 plan 审批阶段即被拒，purging 深验证当前生产零执行。当前瓶颈是 32 个 planned op、14.2 万 entries 的逐 entry PS 路径安全验证。

### 已实现优化（工作区未提交）

- C# 树快照扫描器整体下沉（`CodexSafeTreeDeleteStatusScan.cs`；entry schema/抛错/reparse/junction/identity 语义逐一同构，异常一律类型化回退 PS 参考路径，PS 路径原样保留）。
- receipt 快路径（`Resolve-CodexSafeTreeDeleteStatusReceiptFastOperation`；T1 commit 前 plan/txn/policy 三重 live 复核，漂移即回退参考重放）。
- 并行 fallback（runspace pool DOP 8；前缀并查分组防嵌套树 lease 冲突；metrics 全缓冲合并，worker 失败零污染）。
- plan manifest SHA 流式计算；免封送 receipt 核验——根治 PowerShell 方法绑定器对大 string 实参的整串深拷贝（109M 字符单实参 ≈6s、双实参 ≈12s，连同实例 ReferenceEquals 调用也付费；修复后单 op 14.65s → 314ms）。

### 等价与回归（全部 PASS）

- 逐 op 等价：多轮对照 **4467/4467 identical**（added/removed/changed=0，topLevel/blocking equal），semanticSha256=`88d4b67943d7d451931c024ad031a591efcffd528df9acbcb5e0d566d5938ad6` 与冻结基线一致。
- 套件：Status **42/42**（新增 slice 35-42）、UncertainRecovery、Restore、SchemaCompatibility 10/10 全绿；`Validate-ModuleBoundaries.cjs` PASS；`git diff --check` PASS。
- evidence root 零写入：多轮运行前后全量指纹逐字段一致（manifestSha `8f25b06f…`、4467 ops、25,863 entries、policy sha/identity/SDDL 不变）。

### 独立评审（未参与实现的只读 reviewer）与处置

5 条发现全部处置：M1 worker 部分失败后 metrics 双重计数（改全缓冲一次性合并）；L1 receipt 快路径补 per-op try/catch 单 op 降级参考重放；L2 并行分组键改用 AssertDPath 规范化路径；L3 回滚组合矩阵入库（完全回旧串行行为需 `FAST_SCAN=0` + `PARALLEL_FALLBACK=0` + `TREE_FAST=0` 三者）；L4 测试缺口补齐（record A 分支取证为静态管线不可达、改直调钉住；fast/slow 慢腿补 `PARALLEL_FALLBACK=0`；新增 `TREE_FAST=0` 整轮等价）。

### 正式验收（独立 verifier）：第 1 条未通过

三次独立冷启动（串行、独立进程、无预热）：**88.3s / 91.6s / 99.6s，均超 60s**，合同第 1 条 FAIL。归因上下文（不构成豁免）：同代码在本机安静窗口实测 42.7s（净载）与 54.2s 达标；本机自 ~23:07 起持续慢态，三轮分段显示耗时集中在 I/O 型的 plan 读取与树物化。其余验收条全部 PASS：evidence 零写入（9/9 指纹字段相等）、逐 op 等价（4467/4467）、评审发现闭环抽查（M1/L1/L2 代码现状确认）、套件与门禁全绿。

### 遗留与下一步

1. 待本机安静窗口重跑三次冷启动正式验收；安静态证据（42.7s/54.2s）表明达标可行，但正式合同尚未满足，本票不关闭。
2. 基线分叉待 issue owner 裁决：23 个生产 op 上纯参考解析器输出（manual-review+双错误）≠ 冻结基线（inconsistent+单错误，C# fast scan 形状）；修复尝试与「逐 op 等价」验收直接冲突（equivalence changed=23），已回退并由 slice 41 双侧钉住。分叉方向（收窄 `:4214` 语义或重建基线）需裁决，详据见 IMPLEMENTATION.md N4 段。
3. 全部改动与证据未提交：5 个跟踪文件（`scripts/lib/CodexSafeTreeDeleteStatusScan.cs`、`scripts/lib/CodexSafeTreeDelete.ps1`、`tests/Test-CodexSafeTreeDeleteStatus.ps1`、`modules/manifest.json`、`.gitignore`）+ 未跟踪的 `reports/issue58-20260908/`（FINDINGS.md、IMPLEMENTATION.md、acceptance-* 三轮原始数据等）。commit/push/部署按后续具体授权执行。

完整记录：`reports/issue58-20260908/FINDINGS.md`（基线调查）与 `reports/issue58-20260908/IMPLEMENTATION.md`（实现、评审处置、验收，均为本地未跟踪文件）。
