# 统一环境治理上下文

本项目用于治理本机开发环境：先盘点事实，再生成 dry-run 计划和更新准备报告，最后在明确授权下逐项迁移或调整配置。

核心原则是：该共享的共享，该隔离的隔离。工具运行时、共享缓存和全局 CLI 可以在 D 盘形成稳定入口；项目本地 `.venv`、`node_modules`、服务状态和凭据相关目录默认保持项目隔离或人工审查。

## 必读政策

- D 盘布局、环境分类、迁移授权、验证和回滚边界见 `docs/env-governance/d-drive-layout-and-migration-policy.md`。

## 当前事实基线

- 当前可信报告链已重建：inventory schema 3、readiness schema 3、backup retention dry-run schema 2；本次重建的当前 JSON/Markdown 报告对使用 `generationId` 与源 JSON SHA-256 配对校验。
- 当前生产 backup retention dry-run 的覆盖已计账但不完整（`coverageComplete=false`），真实候选为 0；apply 安全门已拒绝生成，因此当前没有可发布的 schema 2 apply manifest。旧 schema 1 manifest 快照已从项目报告中移除，但没有删除任何备份源数据。
- 只读盘点报告：`reports/env-inventory/REPORT.md`
- dry-run 迁移计划：`reports/env-migration-plan/PLAN.md`
- 统一更新准备报告：`reports/env-update-readiness/REPORT.md`
- 失效 PATH 入口清理 dry-run：`reports/stale-path-entry-cleanup-dry-run/PLAN.md`
- 失效 PATH 入口清理 issue：`.scratch/unified-env/issues/13-stale-path-entry-cleanup-dry-run.md`
- 项目本地环境审查：`reports/project-local-env-review/REPORT.md`
- 项目本地环境重建 dry-run：`reports/project-local-env-rebuild-plan/PLAN.md`
- 项目本地环境分类刷新：`.scratch/unified-env/issues/12-project-local-env-classification-refresh.md`
- 当前备份膨胀治理 dry-run：`reports/backup-retention-dry-run-current/BACKUP-RETENTION-DRY-RUN.md`
- `codex_switch` 安装回滚备份保留 issue：`.scratch/unified-env/issues/14-codex-switch-installed-backup-retention.md`
- 备份保留 apply 执行 issue：`.scratch/unified-env/issues/15-backup-retention-apply-execution.md`
- `codex_switch` 旧式平铺备份文件删除 issue：`.scratch/unified-env/issues/16-codex-switch-flat-backup-delete.md`
- 三类人工审查项删除 issue：`.scratch/unified-env/issues/17-manual-review-cache-staging-backup-delete.md`
- 环境更新执行报告：`reports/env-update-execution-20260706/REPORT.md`
- `codex-account-switch` 依赖更新 dry-run：`reports/codex-account-switch-dependency-update-dry-run/PLAN.md`
- 可信盘点设计：`docs/specs/2026-07-10-environment-inventory-trust-design.md`
- 可信盘点实施计划：`docs/plans/2026-07-10-environment-inventory-trust-implementation.md`
- Codex 主机钩子采用显式冷路径 reconciler；`scripts/Invoke-CodexHostHookReconciliation.ps1` 是唯一当前生产入口，提供 `Check`、`Repair` 和受 evidence 约束的 `Restore`，受管 lifecycle hooks 为 state preflight、Serena activation、cleanup 与 reminder。它不写入 `approval_policy`、`sandbox_mode`、`features.hooks` 或 `unified_exec`；省略 `features.hooks` 时遵循官方默认启用，并保留合法的 inline `[hooks]`。退役 hook 是单向清理项，Restore 不会重建。旧 ProductionFull / registration-repair 生产 façade 已退役，只保留 fixture/core 历史测试价值。Serena 中性启动并在任务内按绝对 workspace root 显式激活；受管 project trust 只覆盖 manifest 中列出的精确项目根。接口与安全边界见 `docs/specs/2026-07-11-host-hook-reconciliation-design.md`。
- 本机 Skill Catalog 生成器位于 `scripts/generate_skill_catalog.py`：只读取本机 active/system/plugin-cache 与 ledger，默认 dry-run，写出时只允许 D 盘本机派生路径；它不安装或更新 skill、不联网、不读凭据、不注册 hook。实现计划见 `docs/plans/2026-07-13-local-skill-catalog-implementation.md`；一次性运行证据按 run id 写入 `D:\Codex\.codex\run-evidence\`。
- Skill 安装/更新的实际写入入口是 `D:\Codex\.codex\scripts\install-skill-guarded.cmd`；项目源文件为 `scripts/install_skill_guarded.py` 与 `scripts/install-skill-guarded.cmd`，安装完成必须同时通过 SOURCE/ledger、资源闭包和 catalog 后置校验。设计见 `docs/specs/2026-07-14-skill-install-guarded-wrapper.md`。
- 功能钩子分层恢复的 path inventory/state policy、`codex-state-preflight`、Serena reminder/cleanup/activation、provider/GitHub 显式维护和 production/legacy manifest 分离均已有实现，并通过定向 fixture 回归。fixture 全量 reconciler 回归不依赖 live 配置所有者；仅 live Repair 与 live 验收仍待配置所有者明确 Serena 配置及权限策略来源，不得从历史 evidence 推断或自动写入这些值。对应设计与实施记录保留在 `docs/specs/2026-07-13-functional-hook-preflight-design.md`、`docs/plans/2026-07-13-functional-hook-preflight.md`。
- GitHub/收尾 skill 的默认分支策略已完成实现与验证：默认分支用 remote HEAD 与 GitHub `defaultBranchRef` 双证据解析，临时分支在确认后合入并双端清理，历史 patch-stack 只报告。设计与实施记录见 `docs/specs/2026-07-13-github-default-branch-skill-policy-design.md` 和 `docs/plans/2026-07-13-github-default-branch-skill-policy-implementation.md`；一次性运行证据按 run id 写入 `D:\Codex\.codex\run-evidence\`。

这些报告是事实快照，不是执行授权。真实迁移、PATH 修改、全局管理器更新或删除前必须重新生成最新基线，并取得具体项授权。
