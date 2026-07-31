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

- `docs/specs/2026-07-24-safe-tree-delete-capability.md`

## 测试

```powershell
node .\scripts\Run-PowerShellTests.cjs --module host-safety --list
```

## 依赖方向

`scripts/lib/CodexHostSafety.ps1` 是通用 capability I/O、路径校验和原子发布的唯一实现。`CodexHookPolicy.ps1` 与 safe-delete 入口分别直接加载它；本模块不依赖 hook policy。
