---
type: reference
title: 宿主安全模块上下文
tags: [宿主安全, 模块, safe-delete]
intent: 定义通用 I/O、路径安全、原子发布和树删除的内部平台边界
---

# 宿主安全模块

## 范围

本模块是仓库内部平台，拥有 handle-bound I/O、D 盘路径与 reparse 校验、原子报告发布、可信报告输入和 safe-tree-delete 能力。它不是独立产品，也不在当前阶段拆成 Git 仓库。

## 接口

safe delete 的宿主公开入口是 gate shim `D:\Codex\.codex\scripts\invoke-safe-tree-delete.ps1`（2026-09-03 入口契约：canonical，POSIX shell 经托管 pwsh 直调；仓库源是 `scripts/invoke-codex-safe-tree-delete-gate-shim.ps1`）；`D:\Codex\.codex\scripts\invoke-safe-tree-delete.cmd` 是 cmd 语境（任务计划、cmd 脚本）兼容启动器，只 pin pwsh 再调 shim（仓库源是 `scripts/invoke-codex-safe-tree-delete.cmd`）。仓库内部模块只通过 manifest 登记的 `scripts/lib/` 稳定 seam 使用 handle-bound I/O、用户环境事务、路径安全、可信输入和原子报告发布；`modules/host-safety/lib/` 是实现目录，不是跨模块入口。调用者不应跨过这些 seam 调用内部删除函数。

## 权威合同

- 删除语义与生产 policy：`docs/specs/2026-07-24-safe-tree-delete-capability.md`
- `retired-evidence-root` 独立合同：`docs/specs/2026-09-15-safe-tree-delete-retired-evidence-root.md`。#59 子票实现已闭环：生产 policy 零本用途条目；GitHub 关闭待用户授权，不在本文缓存 live tracker。
- 性能优化（Plan C# 单遍 walker 已落地、AC1 达标；生产并行 Purge 已接线；端到端 6x 正式验收待环境安静窗口重跑，见 #56）：`docs/specs/2026-08-13-safe-tree-delete-performance-optimization.md`

Plan 阶段自 2026-08-27（#56 Wave A）默认走 C# 单遍 walker（`scripts/lib/CodexSafeTreeDeletePlanSnapshot.cs`）；plan.json 合同不变，等价性与双模式回归见 `reports/safe-tree-delete-issue56-20260827/`。生产排障回退：env `CODEX_SAFE_TREE_DELETE_PLAN_CSHARP_WALKER=0` 强制回 PowerShell 三遍路径（仅字符串 '0' 生效）。

性能史诗 #26 子票 #32/#40/#41/#42 已于 2026-08-19 关闭，现役状态与实测数字以性能 spec「操作者指南」为准；`reports/safe-tree-delete-issue26-20260817/CLOSEABLE.md` 是 2026-08-17 时点快照。

控制面收尾（Archive、退出码传递、`complete` 聚合）以 `docs/specs/2026-07-24-safe-tree-delete-capability.md` 为准：归档合格 terminal 不蕴含 `complete=true`；受管中间层必须转发 `$LASTEXITCODE`。2026-08-13 现场快照见 `reports/safe-tree-delete-control-plane-closeout-20260814/REPORT.md`，不是现役计数。控制面收尾票（#18 系列）状态以 GitHub live tracker 为准，不在本文缓存。

Status 的 C# fast scan 只裁决 producer 规范形态输入，其余回退 `Resolve-CodexSafeTreeDeleteStatusOperation`；`CODEX_SAFE_TREE_DELETE_STATUS_FAST_SCAN=0` 强制参考路径。改认证链时须保留 fast/slow 等价验证。#49 的 2026-08-23 验收是历史样本，不覆盖 #58 的巨型 plan 回归。

处理 Status 性能、approved-plan receipt 或部署验收时，读性能 spec 的「Status 冷启动与大 plan 回退（#49 / #58）」节：该处维护 receipt 复用、live plan/policy 重读边界、#58 的 `DONE_WITH_CONCERNS` 验收状态和剩余限制。Apply/Purge 的 `SessionHashCache` 不属于此优化；源码发布、宿主委托路径和正式部署验收分别核验。

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

## 依赖方向

`scripts/lib/CodexHostSafety.ps1` 是通用 capability I/O、路径校验、原子发布和严格 JSON 属性合同的唯一实现。`CodexHookPolicy.ps1`、state path inventory、repair transaction 与 safe-delete 入口分别直接加载它；本模块不依赖 hook policy。
