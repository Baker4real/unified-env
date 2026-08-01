---
type: reference
title: 统一环境治理上下文
tags: [环境治理, 项目上下文]
intent: 定位统一环境项目的治理目标、边界和必读政策
---

# 统一环境治理上下文

本项目用于治理本机开发环境：先盘点事实，再生成 dry-run 计划和更新准备报告，最后在明确授权下逐项迁移或调整配置。

核心原则是：该共享的共享，该隔离的隔离。工具运行时、共享缓存和全局 CLI 可以在 D 盘形成稳定入口；项目本地 `.venv`、`node_modules`、服务状态和凭据相关目录默认保持项目隔离或人工审查。

## 必读政策

- D 盘布局、环境分类、迁移授权、验证和回滚边界见 `docs/env-governance/d-drive-layout-and-migration-policy.md`。

## 模块上下文

本项目保持为单一治理仓库，内部划分为 `dev-environment`、`codex-host`、`skill-supply-chain`、`host-safety` 和 `workstation-operations` 五个模块。处理具体任务时，先读 `modules/README.md`，再读对应 `modules/<module-id>/CONTEXT.md`；文件归属、对外接口、测试 profile 和依赖以 `modules/manifest.json` 为真源。

第一阶段模块迁移已完成：现役脚本、部署路径和历史合同文档保持原位，通用 capability I/O 由 `scripts/lib/CodexHostSafety.ps1` 唯一实现。`CodexHookPolicy.ps1` 依赖该模块，safe-delete 直接加载该模块，不再形成 `host-safety -> codex-host` 反向依赖。

## 报告与当前事实边界

- `reports/` 下的 JSON/Markdown 报告是带时间戳的事实快照；`generationId` 与源 JSON SHA-256 只证明同一次生成的配对一致，不证明进程、用户环境或工具入口仍是当前状态。任何决策或执行前必须重新生成相关报告并现场核验。
- Backup retention 的现役合同为 schema 3 dry-run；apply manifest 必须消费现场重新验证且覆盖完整的 production dry-run，并且只接受非零 directory candidates。当前计数、覆盖状态与是否有 manifest 只从 `reports/backup-retention-dry-run-current/` 的最新报告读取，不在本长期文档重复快照。
- 只读盘点快照：`reports/env-inventory/REPORT.md`
- dry-run 迁移计划：`reports/env-migration-plan/PLAN.md`
- 统一更新准备快照：`reports/env-update-readiness/REPORT.md`
- 失效 PATH 入口清理 dry-run：`reports/stale-path-entry-cleanup-dry-run/PLAN.md`
- 项目本地环境审查：`reports/project-local-env-review/REPORT.md`
- 项目本地环境重建 dry-run：`reports/project-local-env-rebuild-plan/PLAN.md`
- 当前备份膨胀治理 dry-run：`reports/backup-retention-dry-run-current/BACKUP-RETENTION-DRY-RUN.md`
- 环境更新执行报告：`reports/env-update-execution-20260706/REPORT.md`
- `codex-account-switch` 依赖更新 dry-run：`reports/codex-account-switch-dependency-update-dry-run/PLAN.md`
- 可信盘点设计：`docs/specs/2026-07-10-environment-inventory-trust-design.md`
- 可信盘点实施计划：`docs/plans/2026-07-10-environment-inventory-trust-implementation.md`
- Codex 主机钩子采用显式冷路径 reconciler；`scripts/Invoke-CodexHostHookReconciliation.ps1` 是唯一当前生产入口，提供 `Check`、`Repair` 和受 evidence 约束的 `Restore`，受管 lifecycle hooks 为 state preflight、Serena activation、cleanup 与 reminder。生产 wrapper 统一经受管 hidden-console launcher 启动最终 PowerShell/Python 进程，显式禁止新控制台窗口并保留协议流和退出码。协调器不写入 `approval_policy`、`sandbox_mode`、`features.hooks` 或 `unified_exec`；省略 `features.hooks` 时遵循官方默认启用，并保留合法的 inline `[hooks]`。退役 hook 是单向清理项，Restore 不会重建。旧 ProductionFull / registration-repair 生产 façade 已退役，只保留 fixture/core 历史测试价值。Serena 中性启动并在任务内按绝对 workspace root 显式激活；manifest 的 `trustedProjects` 只补齐列出的精确项目根，`retiredProjectTrusts` 以精确根为 denylist 删除对应普通/array table 及 TOML descendants，evidence 与 Restore 不得保留或回流退役 trust，其余用户 trust 保留。接口与安全边界见 `docs/specs/2026-07-11-host-hook-reconciliation-design.md`。
- Codex/agent 发起的宿主递归目录删除使用受管 `Plan` / `Apply` / `Purge` 入口；能力边界、回滚语义和仍待迁移的仓库内部清理见 `docs/specs/2026-07-24-safe-tree-delete-capability.md`。
- 已明确退役的 Superpowers 及其他 retired skill/plugin 采用 ledger 与显式 allowlist 驱动的单向清理；对应 active surface、source clone、plugin cache 和 payload backup 均不保留本机副本，运行证据不含 payload。官方异步刷新的远端 available catalog 由独立 catalog-only guard 最终收敛；该 guard 只过滤固定 `name` / `id` 配对，不调用综合退休清理器，也不触碰安装目录。运维与回滚见 `docs/env-governance/remote-plugin-catalog-guard.md`。
- Skill Catalog 的仓库源生成器位于 `scripts/generate_skill_catalog.py`：只读取本机 active/system/plugin-cache 与 ledger，默认 dry-run，写出时只允许 D 盘本机派生路径；它不安装或更新 skill、不联网、不读凭据、不注册 hook。宿主部署状态以 `modules/skill-supply-chain/CONTEXT.md` 为准，不能由仓库源存在推断已部署；实现计划见 `docs/plans/2026-07-13-local-skill-catalog-implementation.md`。
- Skill 安装/更新的实际写入入口是 `D:\Codex\.codex\scripts\install-skill-guarded.cmd`；项目部署闭包由 `scripts/skill_source_record.py`、`scripts/generate_skill_catalog.py`、`scripts/install_skill_guarded.py` 与 `scripts/install-skill-guarded.cmd` 组成，安装完成必须同时通过 SOURCE/ledger、资源闭包和 catalog 后置校验。设计见 `docs/specs/2026-07-14-skill-install-guarded-wrapper.md`。
- 功能钩子分层恢复的 path inventory/state policy、`codex-state-preflight`、Serena reminder/cleanup/activation、provider/GitHub 显式维护和 production/legacy manifest 分离均已有实现，并通过定向 fixture 回归。fixture 全量 reconciler 回归不依赖 live 配置所有者；获授权的 live Repair 与验收只通过当前 reconciler 和当前主机状态执行，不得从历史 evidence 推断或手工写入 Serena 配置或权限策略值。对应设计与实施记录保留在 `docs/specs/2026-07-13-functional-hook-preflight-design.md`、`docs/plans/2026-07-13-functional-hook-preflight.md`。
- Git 的唯一现役发布合同要求全部普通 closeout/push skill（包括 GitHub `github:yeet` 与 `neat-freak`）只发布到用户拥有远端的 `main`。2026-07-13 版本化 default-branch overlay 及现役插件 cache 尚未收敛，当前标为 `pending drift`，不能覆盖 `main`-only 政策或授权非 `main` 发布。临时分支只在事前确认后使用，历史 patch-stack 只报告。历史设计与实施记录见 `docs/specs/2026-07-13-github-default-branch-skill-policy-design.md` 和 `docs/plans/2026-07-13-github-default-branch-skill-policy-implementation.md`。

这些报告是事实快照，不是执行授权。真实迁移、PATH 修改、全局管理器更新或删除前必须重新生成最新基线，并取得具体项授权。
