---
type: reference
title: 开发环境模块上下文
tags: [环境治理, 模块, 迁移]
intent: 定义环境盘点、dry-run 迁移、PATH 与报告链的责任边界
---

# 开发环境模块

## 范围

本模块拥有环境事实盘点、更新准备、dry-run 迁移、PATH 治理、项目本地环境审查和备份保留报告。报告是带时间戳的事实快照，不是执行授权。

## 不属于本模块

- Codex hook、Serena/CodeGraph 运行时和 remote catalog guard 属于 `codex-host`。
- Skill 安装、catalog、ledger 和 Git overlay 属于 `skill-supply-chain`。
- 句柄绑定 I/O、通用路径安全和原子发布属于 `host-safety`。

## 权威合同

- `docs/env-governance/d-drive-layout-and-migration-policy.md`
- `docs/specs/2026-07-10-environment-inventory-trust-design.md`

## 接口与测试

对外接口是 `scripts/Invoke-EnvInventory.ps1`、`scripts/New-EnvMigrationPlan.ps1` 及其他 manifest 登记的报告/dry-run 入口。使用以下命令查看模块的 PowerShell 测试清单：

```powershell
node .\scripts\Run-PowerShellTests.cjs --module dev-environment --list
```

`D:\Codex\.codex\scripts` 里每个文件的 owner 登记在 `managed/codex-scripts/ownership.json`，`scripts/Invoke-CodexScriptsOwnershipLint.ps1` 只读核对：未登记的文件、`source` 不在仓库里、部署脚本没点名该文件都是 error，本机缺登记条目、部署副本与源不一致是 warning。往这个目录部署、手工放入或清理文件时，同时改登记表并跑一次 lint。部署时会改写内容的条目不登记 `source`（`invoke-safe-tree-delete.ps1`：部署工具把 gate holder 库内联进 shim），由部署工具自己的回执核对。

## 依赖

本模块依赖 `host-safety` 提供的路径安全、可信输入和原子报告发布实现。
