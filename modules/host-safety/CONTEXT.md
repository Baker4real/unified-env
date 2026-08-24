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

safe delete 的宿主公开入口仍是 `D:\Codex\.codex\scripts\invoke-safe-tree-delete.cmd`；仓库源入口是 `scripts/invoke-codex-safe-tree-delete.cmd`。仓库内部模块只通过 manifest 登记的 `scripts/lib/` 稳定 seam 使用 handle-bound I/O、用户环境事务、路径安全、可信输入和原子报告发布；`modules/host-safety/lib/` 是实现目录，不是跨模块入口。调用者不应跨过这些 seam 调用内部删除函数。

## 权威合同

- 删除语义与生产 policy：`docs/specs/2026-07-24-safe-tree-delete-capability.md`
- 性能优化（生产并行 Purge 已接线；典型 4x 边界、6x 移交 #56）：`docs/specs/2026-08-13-safe-tree-delete-performance-optimization.md`

性能史诗 #26 子票 #32/#40/#41/#42 已于 2026-08-19 关闭，现役状态与实测数字以性能 spec「操作者指南」为准；`reports/safe-tree-delete-issue26-20260817/CLOSEABLE.md` 是 2026-08-17 时点快照。

控制面收尾（Archive、退出码传递、`complete` 聚合）以 `docs/specs/2026-07-24-safe-tree-delete-capability.md` 为准：归档合格 terminal 不蕴含 `complete=true`；受管中间层必须转发 `$LASTEXITCODE`。2026-08-13 现场快照见 `reports/safe-tree-delete-control-plane-closeout-20260814/REPORT.md`，不是现役计数。控制面收尾票（#18 系列）状态以 GitHub live tracker 为准，不在本文缓存。

Status 冷启动（#49）2026-08-23 达标关闭：正式三联 9.762 / 9.791 / 9.237s（同日基线 199.357s），协议与证据见 `reports/safe-tree-delete-issue49-20260823/`（优化前基线 189/184/182s 见 20260817 目录）。实现为 C# 并行 fast scan（`scripts/lib/CodexSafeTreeDeleteStatusScan.cs`，DOP=4，kill switch `CODEX_SAFE_TREE_DELETE_STATUS_FAST_SCAN=0`）：只裁决 producer 规范形态输入，其余一律回退 `Resolve-CodexSafeTreeDeleteStatusOperation`；改认证链时须同步复刻或依赖回退并重跑 fast-vs-slow 对照。#26–#43 的 Apply/Purge `SessionHashCache` 不是 Status 优化。

## 测试

```powershell
node .\scripts\Run-PowerShellTests.cjs --module host-safety --list
```

## 依赖方向

`scripts/lib/CodexHostSafety.ps1` 是通用 capability I/O、路径校验、原子发布和严格 JSON 属性合同的唯一实现。`CodexHookPolicy.ps1`、state path inventory、repair transaction 与 safe-delete 入口分别直接加载它；本模块不依赖 hook policy。
