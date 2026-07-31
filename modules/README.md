---
type: index
title: 模块导航
tags: [环境治理, 模块化, 架构]
intent: 说明单仓模块边界、接口、依赖与迁移顺序
---

# 模块导航

本项目保持为一个 Git 仓库，但不再作为单一上下文维护。模块的知识入口位于 `modules/<module-id>/CONTEXT.md`，文件归属、对外接口、测试和依赖的机器可校验真源是 `modules/manifest.json`。

| 模块 | 职责 | 对外 seam |
| --- | --- | --- |
| `dev-environment` | 盘点、dry-run 迁移、PATH、备份与报告 | `Invoke-EnvInventory.ps1` 及 `New-*` 计划/报告入口 |
| `codex-host` | Hooks、state preflight、Serena/CodeGraph 运行时、remote catalog guard | `Invoke-CodexHostHookReconciliation.ps1` 与 `Invoke-CodexRemotePluginCatalogGuard.ps1` |
| `skill-supply-chain` | Skill 来源、安装事务、catalog、ledger 与 Git overlay | `install-skill-guarded.cmd`、catalog 生成器与部署入口 |
| `host-safety` | 句柄绑定 I/O、路径安全、原子发布、safe delete | manifest 登记的 `scripts/lib/` seam 与 `invoke-codex-safe-tree-delete.cmd` |
| `workstation-operations` | 设备事实、跨设备验收与工作站集成政策 | 设备文档与 Sub2API 更新政策 |

## 依赖方向

```text
dev-environment -----> host-safety <----- codex-host
skill-supply-chain    (currently independent)
workstation-operations (documentation/integration only)
```

`CodexHostSafety.ps1` 是通用 capability I/O、路径校验和原子发布的唯一实现。`codex-host` 与 safe-delete 都依赖该 seam；safe-delete 不再加载 hook 专用 policy，现役入口路径保持不变。

## 迁移规则

- 当前处于 `expand` 阶段：先建立 ownership、接口和测试 seam，不移动部署路径。
- 新增仓库文件必须在 manifest 中有且仅有一个 owner；根治理文件只能进入显式 `shared` 列表。
- 迁移实现时保留旧入口 adapter；只有新模块实现、测试、部署和回滚都独立通过后，才进入 `contract` 阶段。
- 历史 spec/plan 暂不移动；部分 dated 文档仍包含现役合同，模块 CONTEXT 只引用真源，不复制合同正文。

## 校验

```powershell
node .\scripts\Validate-ModuleBoundaries.cjs --json
node .\tests\Test-ModuleBoundaries.cjs
node .\scripts\Run-PowerShellTests.cjs --module dev-environment --list
```
