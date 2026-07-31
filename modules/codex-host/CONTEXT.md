---
type: reference
title: Codex 宿主模块上下文
tags: [Codex, 模块, hooks]
intent: 定义 Codex hooks、state、代码智能运行时与 remote catalog 守卫的责任边界
---

# Codex 宿主模块

## 范围

本模块拥有 Codex hook reconciler、state preflight、Serena/CodeGraph 宿主运行时、retired project 清理和 remote plugin catalog guard。

## 不属于本模块

- 通用句柄绑定 I/O、路径安全、原子发布和 safe delete 属于 `host-safety`。
- Skill 来源、安装事务、ledger 与 Git overlay 属于 `skill-supply-chain`。
- 设备差异和 Sub2API 集成政策属于 `workstation-operations`。

## 权威合同

- `docs/specs/2026-07-11-host-hook-reconciliation-design.md`
- `docs/env-governance/remote-plugin-catalog-guard.md`

旧 hook 设计和 functional preflight 文档仍被 fixture 与历史拒绝合同引用，本阶段不移动或归档。

## 接口与测试

主接口是 `scripts/Invoke-CodexHostHookReconciliation.ps1` 和 `scripts/Invoke-CodexRemotePluginCatalogGuard.ps1`。定向测试清单：

```powershell
node .\scripts\Run-PowerShellTests.cjs --module codex-host --list
```

Vendor-abort stress 测试会写入受管 D 盘 evidence，只在明确的宿主验收中执行，不作为轻量 module smoke test。

## 依赖

本模块依赖 `host-safety` 的 handle-bound I/O 与受管发布能力。
