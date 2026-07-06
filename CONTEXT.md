# 统一环境治理上下文

本项目用于治理本机开发环境：先盘点事实，再生成 dry-run 计划和更新准备报告，最后在明确授权下逐项迁移或调整配置。

核心原则是：该共享的共享，该隔离的隔离。工具运行时、共享缓存和全局 CLI 可以在 D 盘形成稳定入口；项目本地 `.venv`、`node_modules`、服务状态和凭据相关目录默认保持项目隔离或人工审查。

## 必读政策

- D 盘布局、环境分类、迁移授权、验证和回滚边界见 `docs/env-governance/d-drive-layout-and-migration-policy.md`。

## 当前事实基线

- 只读盘点报告：`reports/env-inventory/REPORT.md`
- dry-run 迁移计划：`reports/env-migration-plan/PLAN.md`
- 统一更新准备报告：`reports/env-update-readiness/REPORT.md`
- 失效 PATH 入口清理 dry-run：`reports/stale-path-entry-cleanup-dry-run/PLAN.md`
- 失效 PATH 入口清理 issue：`.scratch/unified-env/issues/13-stale-path-entry-cleanup-dry-run.md`
- 项目本地环境审查：`reports/project-local-env-review/REPORT.md`
- 项目本地环境重建 dry-run：`reports/project-local-env-rebuild-plan/PLAN.md`
- 项目本地环境分类刷新：`.scratch/unified-env/issues/12-project-local-env-classification-refresh.md`
- 备份膨胀治理 dry-run：`D:\Codex\.codex\run-evidence\env-governance\backup-retention-20260701-164920\BACKUP-RETENTION-DRY-RUN.md`
- `codex_switch` 安装回滚备份保留 issue：`.scratch/unified-env/issues/14-codex-switch-installed-backup-retention.md`
- 备份保留 apply 执行 issue：`.scratch/unified-env/issues/15-backup-retention-apply-execution.md`
- 备份保留 apply 执行证据：`D:\Codex\.codex\run-evidence\env-governance\backup-retention-apply-20260701-160956\EXECUTION.md`
- `codex_switch` 旧式平铺备份文件删除 issue：`.scratch/unified-env/issues/16-codex-switch-flat-backup-delete.md`
- `codex_switch` 旧式平铺备份文件删除证据：`D:\Codex\.codex\run-evidence\env-governance\codex-switch-flat-backup-delete-20260701-162530\EXECUTION.md`
- 三类人工审查项删除 issue：`.scratch/unified-env/issues/17-manual-review-cache-staging-backup-delete.md`
- 三类人工审查项删除证据：`D:\Codex\.codex\run-evidence\env-governance\manual-review-cleanup-20260701-164124\EXECUTION.md`
- Codex 主机更新收尾交接：`docs/handoffs/2026-07-06-codex-host-update-closeout-handoff.md`
- Codex 主机更新证据：`D:\Codex\.codex\run-evidence\codex-update-20260706-104516`
- PATH 清理执行证据：`D:\Codex\.codex\run-evidence\env-governance\path-cleanup-20260701-151054\EXECUTION.md`
- 备份清理 apply manifest 设计：`reports/backup-retention-apply-manifest/BACKUP-RETENTION-APPLY-MANIFEST.md`
- `codex-account-switch` 依赖更新 dry-run：`reports/codex-account-switch-dependency-update-dry-run/PLAN.md`
- apply manifest 交接：`docs/handoffs/2026-07-01-backup-retention-apply-manifest-handoff.md`
- 最新清理收尾交接：`docs/handoffs/2026-07-01-env-governance-cleanout-closeout-handoff.md`
- 备份清理交接：`docs/handoffs/2026-06-30-backup-retention-runtime-cleanup-handoff.md`
- 项目本地环境交接：`docs/handoffs/2026-06-30-project-local-env-handoff.md`
- 失效 PATH 入口清理交接：`docs/handoffs/2026-07-01-stale-path-entry-cleanup-dry-run-handoff.md`

这些报告是事实快照，不是执行授权。真实迁移前必须重新生成最新基线。
