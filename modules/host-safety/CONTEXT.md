---
type: reference
title: 宿主安全模块上下文
tags: [宿主安全, 模块, safe-delete]
intent: 定义通用 I/O、路径安全、原子发布和树删除的内部平台边界
---

# 宿主安全模块

## 范围

本模块是仓库内部平台，拥有 handle-bound I/O、D 盘路径与 reparse 校验、原子报告发布、可信报告输入、安全诊断与恢复工具，以及 safe-tree-delete 能力。它不是独立产品，也不在当前阶段拆成 Git 仓库。

## 接口

safe delete 的宿主公开入口是 gate shim `D:\Codex\.codex\scripts\invoke-safe-tree-delete.ps1`（2026-09-03 入口契约：canonical，POSIX shell 经托管 pwsh 直调；仓库源是 `scripts/invoke-codex-safe-tree-delete-gate-shim.ps1`）；`D:\Codex\.codex\scripts\invoke-safe-tree-delete.cmd` 是 cmd 语境（任务计划、cmd 脚本）兼容启动器，只 pin pwsh 再调 shim（仓库源是 `scripts/invoke-codex-safe-tree-delete.cmd`）。仓库内部模块只通过 manifest 登记的 `scripts/lib/` 稳定 seam 使用 handle-bound I/O、用户环境事务、路径安全、可信输入和原子报告发布；`modules/host-safety/lib/` 是实现目录，不是跨模块入口。调用者不应跨过这些 seam 调用内部删除函数。

## 权威合同

- 浏览器语言/隐私复测、日志与 Markdown 章节安全投影、PowerShell 预检与 Explorer 恢复：`docs/env-governance/host-diagnostics.md`。源码在 `managed/host-diagnostics/`，部署入口 `scripts/Deploy-HostDiagnostics.ps1` 默认只读核对；设备修复状态留在设备文档或运行证据。
- 删除语义与生产 policy：`docs/specs/2026-07-24-safe-tree-delete-capability.md`
- 批量清理状态、崩溃恢复、策略快照与目录身份验收：`docs/specs/2026-10-10-safe-cleanup-job.md`。入口 `scripts/Invoke-SafeCleanupJob.ps1`；状态不扫描全部历史交易。
- `retired-evidence-root` 独立合同：`docs/specs/2026-09-15-safe-tree-delete-retired-evidence-root.md`。本用途条目只作一次性许可；生产 policy 不得残留（测试钉死）。live tracker 以 GitHub Issues 为准，不在本文缓存。
- 性能优化（Plan C# 单遍 walker 已落地、AC1 达标；生产并行 Purge 已接线；端到端 6x 正式验收待环境安静窗口重跑，见 #56）：`docs/specs/2026-08-13-safe-tree-delete-performance-optimization.md`

Plan 阶段自 2026-08-27（#56 Wave A）默认走 C# 单遍 walker（`scripts/lib/CodexSafeTreeDeletePlanSnapshot.cs`）；plan.json 合同不变，等价性与双模式回归见 `reports/safe-tree-delete-issue56-20260827/`。生产排障回退：env `CODEX_SAFE_TREE_DELETE_PLAN_CSHARP_WALKER=0` 强制回 PowerShell 三遍路径（仅字符串 '0' 生效）。

safe-tree-delete lib 编译的全部 C# 组件（Status fast scan、Plan walker 与其余 native 组件）只经 `scripts/lib/CodexHostSafetyNativeLoader.ps1` 加载（#86）：source 变化只发布新的内容寻址 generation（`<variant>\<compositeSha256>\`），不改写已发布文件，所以工作树与生产互不干扰。env=0 的 base variant 不含 PlanSnapshot，但仍含 Status fast scan。新增 C# 组件只加入 loader 的 source 集，不另建缓存。旧的固定路径 `CodexSafeTreeDeleteStatusScan.dll` 及其 `.sha256` 不再被读写或加载。回归见 `tests/Test-CodexSafeTreeDeleteNativeLoading.ps1`。

性能史诗 #26 子票 #32/#40/#41/#42 已于 2026-08-19 关闭，现役状态与实测数字以性能 spec「操作者指南」为准；`reports/safe-tree-delete-issue26-20260817/CLOSEABLE.md` 是 2026-08-17 时点快照。

控制面收尾（Archive、退出码传递、`complete` 聚合）以 `docs/specs/2026-07-24-safe-tree-delete-capability.md` 为准：归档合格 terminal 不蕴含 `complete=true`；受管中间层必须转发 `$LASTEXITCODE`。2026-08-13 现场快照见 `reports/safe-tree-delete-control-plane-closeout-20260814/REPORT.md`，不是现役计数。控制面收尾票（#18 系列）状态以 GitHub live tracker 为准，不在本文缓存。

Status 的 C# fast scan 只裁决 producer 规范形态输入，其余回退 `Resolve-CodexSafeTreeDeleteStatusOperation`；`CODEX_SAFE_TREE_DELETE_STATUS_FAST_SCAN=0` 强制参考路径。改认证链时须保留 fast/slow 等价验证。#49 的 2026-08-23 验收是历史样本，不覆盖 #58 的巨型 plan 回归。

处理 Status 性能、approved-plan receipt 或部署验收时，读性能 spec 的「Status 冷启动与大 plan 回退（#49 / #58）」节：该处维护 receipt 复用、live plan/policy 重读边界、#58 的 `DONE_WITH_CONCERNS` 验收状态和剩余限制。Apply/Purge 的 `SessionHashCache` 不属于此优化；源码发布、宿主委托路径和正式部署验收分别核验。

BatchPurge 历史查找（spec #73「实现决策 › BatchPurge 单次历史扫描」）默认走 fast 模式：目标去重后、处理第一个目标前整批只扫一次历史，得到只在本次调用内存中有效的「目标（OrdinalIgnoreCase，不做 Unicode 规范化）→ 候选」索引；处理到某个目标时，先对它的候选重做完整参考认证并要求 SHA-256 与扫描时一致，再进入原有分支（多匹配报错、schema 非 2/3 skipAction、3 次存在性探测和隔离目录检查的时机都不变）。`CODEX_SAFE_TREE_DELETE_BATCH_HISTORY_SCAN=0` 退回逐目标参考查找（仅字符串 '0' 生效）。

- **等价前提**：fast 与 reference 等价，依赖 gate 的独占串行，即批处理期间只有本调用写 evidence；本批写入的记录只指向本批已去重的目标，不会成为其他目标的候选。gate 若改成共享锁或允许并发写 evidence，必须先重新论证这个前提，再保留 fast 模式。
- **失败语义**：扫描阶段任何异常使全批 skipped-target-error、`completed=false`；处理阶段候选重新认证失败视为扫描后历史被外部改动，当前及剩余目标 skipped-target-error，已完成目标保留结果。两种模式只在一种组合下错误文本可能不同、动作相同：reference 模式下某目标自身匹配记录的裁决异常若先于全局坏记录被枚举，该目标 `error` 取前者，fast 模式取扫描失败消息。
- **`historyScan` 结果字段**：`mode`、`scanCount`、`enumeratedFiles`、`canonicalFiles`、`fallbackFiles`、`excludedByPrefilter`、`fullyAuthenticated`、`elapsedMs`，失败时另有 `failure`（`phase` 为 `scan` 或 `reauthentication`）。fast 模式 `scanCount` 恒为 1；reference 模式等于目标数，各计数为逐目标累计。C# 预筛属于 #78，落地前扫描阶段逐文件完整认证、`excludedByPrefilter` 恒为 0，`canonicalFiles` 只按位置（run 目录第一层的 `transaction.json`）分类；`fullyAuthenticated` 不含处理阶段的重新认证。
- **测试钩子**：扫描后篡改候选的钩子只在 fixture 入口暴露（`-FixtureAfterBatchHistoryScan`），只在 fast 模式扫描成功后调用；生产入口没有可达路径。回归套件是 `tests/Test-CodexSafeTreeDeleteBatchHistoryScan.ps1`。

## 测试

```powershell
node .\scripts\Run-PowerShellTests.cjs --module host-safety --list
```

约定（2026-08-24 CI 首次全绿后固化）：

- CI 按字母序执行套件且 fail-fast：字母序后段的套件问题只会在前段修复后显形，新增套件的宿主耦合（绝对本机路径、生产 evidence 依赖）要在本地非宿主视角自检。
- 绝对性能阈值在 fixture profile 一律 record-only（`metTarget*=False` 不影响 `ok`，先例 Phase3Integration/PurgeBatch/JournalPerformance）；硬断言只留给确定性/一致性判据，且按环境（如 `GITHUB_ACTIONS`）分支。
- `Test-CodexSafeTreeDeleteFileSystem.ps1` 实卷段提权感知：非提权且无原生 FAT32/exFAT 卷自动记名 skip（`liveFsLeg=skipped-non-elevated`），提权/有原生卷走真实实卷断言。
- 2026-09-01（#57）：safe-tree-delete issue/scale 套件的 ephemeral fixture、journal、work、livefail 与默认 benchmark live JSON 写到 gitignored `.scratch/safe-tree-delete-tests-*`。`reports/safe-tree-delete-issue*` 与冻结 benchmark 目录只作只读输入。
- Phase3 leftover 根是 `D:\agents\run-evidence\safe-tree-delete`：目录存在则 `leftoverGuardMode=production-host` 并执行三断言；不存在则记名 skip `absent-environment`。
- #75 真实历史档位 `Measure-CodexSafeTreeDeleteHistory.ps1 -RealHistory` 默认只读生产 evidence，并经生产 gate shim 跑 Status，只在与用户确认的安静窗口手动运行。`GITHUB_ACTIONS`/`CI` 为 `true` 时记名 skip `ci-environment`，evidence 根不存在时记名 skip `evidence-root-absent`；产物只写 `.scratch/safe-tree-delete-tests-real-history-*`。fixture 套件显式传入 fixture evidence 和替身 shim；新增测量项追加到脚本的 `$items` 列表。

## 依赖方向

`scripts/lib/CodexHostSafety.ps1` 是通用 capability I/O、路径校验、原子发布和严格 JSON 属性合同的唯一实现。`CodexHookPolicy.ps1`、state path inventory、repair transaction 与 safe-delete 入口分别直接加载它；本模块不依赖 hook policy。
