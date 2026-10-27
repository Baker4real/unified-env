---
type: reference
title: Codex 宿主模块上下文
tags: [Codex, 模块, hooks]
intent: 定义 Codex hooks、state、代码智能运行时与 remote catalog 守卫的责任边界
---

# Codex 宿主模块

## 范围

本模块拥有 Codex hook reconciler、state preflight、github-cli SessionStart、Serena/CodeGraph 宿主运行时、retired project 清理和 remote plugin catalog guard。`managed/grok-hooks/`、`managed/cursor-hooks/` 与 `managed/claude-hooks/` 也归本模块落盘，但不进入 `Invoke-CodexHostHookReconciliation.ps1`；现役 Grok/Cursor/Claude Code 注册以 host-runbook 的 Grok Host Hooks、Cursor Host Hooks 与 Claude Code Host Hooks 为准。

## 不属于本模块

- 通用句柄绑定 I/O、路径安全、原子发布和 safe delete 属于 `host-safety`。
- Skill 来源、安装事务、ledger 与 Git overlay 属于 `skill-supply-chain`。
- 设备差异和 Sub2API 集成政策属于 `workstation-operations`。

## 权威合同

- `docs/specs/2026-07-11-host-hook-reconciliation-design.md`
- `docs/env-governance/remote-plugin-catalog-guard.md`

2026-09-06 起 reconciler 的 `config` 检查与 `config.toml` 语义收敛已退役（用户裁决）：不再读取/规范化/改写 `config.toml`，Check 无 config 检查项，Repair 为 Serena context + `hooks.json` 两资源事务，Restore 对含 `config.toml` 的历史 evidence fail closed。根因与边界见 spec 的「config reconciliation 退役」节。

旧 hook 设计和 functional preflight 文档仍被 fixture 与历史拒绝合同引用，本阶段不移动或归档。

## 内部实现

`modules/codex-host/CodexHostHookEvidence.ps1` 拥有 evidence snapshot、managed-hook backup 和 restore manifest 的构建逻辑；`scripts/Invoke-CodexHostHookReconciliation.ps1` 保留稳定生产 seam，并 dot-source 该 module implementation。生命周期重构按同一边界继续收敛，不能把 evidence 写入能力复制回根入口。

## 接口与测试

配置告警走 [只读检查入口](../../docs/env-governance/codex-config-diagnostics.md)：`Check-CodexConfig.py` 分别报告文件、运行时与桌面会话的验证范围，不恢复 config reconciliation。

主接口是 `scripts/Invoke-CodexHostHookReconciliation.ps1` 和 `scripts/Invoke-CodexRemotePluginCatalogGuard.ps1`。定向测试清单：

```powershell
node .\scripts\Run-PowerShellTests.cjs --module codex-host --list
```

Vendor-abort stress 测试会写入受管 D 盘 evidence，只在明确的宿主验收中执行，不作为轻量 module smoke test。

2026-10-27 实测：`handle-consumers` 档约 7 分钟；该档打 live gate，须在安静窗口内从主工作树运行（窗口定义见 capability spec「安静窗口」节）。runner 的 `--only`/`--skip` 标签过滤同样适用于本模块。

## 依赖

本模块依赖 `host-safety` 的 handle-bound I/O 与受管发布能力。
