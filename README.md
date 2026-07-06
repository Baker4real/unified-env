# 统一环境治理

本项目用于治理本机开发环境：先只读盘点事实，再生成 dry-run 计划，最后只在明确授权下逐项迁移、更新或重建。

核心原则：该共享的共享，该隔离的隔离。共享缓存和可复用工具入口优先放到 D 盘；项目本地 `.venv`、`node_modules`、服务状态和凭据目录默认保持隔离。

## 当前状态

- 已迁移低风险 `pip cache` 到 `D:\Codex\.cache\pip`。
- 当前没有新的明确安全迁移候选。
- 项目本地环境已完成分类刷新、审查和重建 dry-run 计划；当前区分项目根环境、嵌套 app、插件 runtime/cache、repair backup 和归档缓存，真实重建仍需 owner 决策。
- 已按授权从 User scope PATH 移除失效项目本地环境入口 `D:\hermes-agent\.venv\Scripts`；最新 PATH 清理 dry-run 候选为 0。
- 已新增备份膨胀治理 dry-run 脚本，当前只读报告把严格保留规则候选和人工审查项分开，并已纳入 `codex_switch` 安装回滚备份；真实清理仍需显式授权。
- 已按用户最终授权执行备份保留 apply：删除 36 个已验证旧备份目录，估算释放 234.11 MB；最新 dry-run 候选为 0，人工审查项仍未自动处理。
- 已按用户单独授权删除 `codex_switch` 旧式平铺备份文件 3 个，估算释放 54.78 MB；其他人工审查项仍未自动处理。
- 已按用户授权删除三类人工审查项 5 个路径，估算释放 1215.85 MB；最新人工审查项为 258 个，3950.71 MB。
- 已完成 `codex-account-switch` 依赖更新 dry-run；当前安全补丁已满足，后续框架 minor 或大版本更新仍需在目标项目中显式授权。
- 已完成 2026-07-06 Codex 主机更新收尾：Codex CLI、Node、npm、Git、gh、uv、sqlite3、CodeGraph 和 Serena 主链路已验证；Serena 运行在官方 Python 3.14.6 上，并通过 uv override 使用 `anthropic==0.116.0`。

## 关键入口

- 项目上下文：`CONTEXT.md`
- 迁移政策：`docs/env-governance/d-drive-layout-and-migration-policy.md`
- 本地 issue：`.scratch/unified-env/issues/`
- 交接文档：`docs/handoffs/`
- 最新清理收尾交接：`docs/handoffs/2026-07-01-env-governance-cleanout-closeout-handoff.md`
- Codex 主机更新收尾交接：`docs/handoffs/2026-07-06-codex-host-update-closeout-handoff.md`

## 主要报告

- 只读盘点：`reports/env-inventory/REPORT.md`
- 迁移 dry-run：`reports/env-migration-plan/PLAN.md`
- pip cache 迁移证据：`reports/env-migration-execution/pip-cache/`
- 更新准备：`reports/env-update-readiness/REPORT.md`
- 失效 PATH 入口清理 dry-run：`reports/stale-path-entry-cleanup-dry-run/PLAN.md`
- 项目本地环境审查：`reports/project-local-env-review/REPORT.md`
- 项目本地环境重建 dry-run：`reports/project-local-env-rebuild-plan/PLAN.md`
- 备份膨胀治理 dry-run 证据：`D:\Codex\.codex\run-evidence\env-governance\backup-retention-20260701-164920\BACKUP-RETENTION-DRY-RUN.md`
- 备份保留 apply 执行证据：`D:\Codex\.codex\run-evidence\env-governance\backup-retention-apply-20260701-160956\EXECUTION.md`
- `codex_switch` 旧式平铺备份文件删除证据：`D:\Codex\.codex\run-evidence\env-governance\codex-switch-flat-backup-delete-20260701-162530\EXECUTION.md`
- 三类人工审查项删除证据：`D:\Codex\.codex\run-evidence\env-governance\manual-review-cleanup-20260701-164124\EXECUTION.md`
- 备份清理 apply manifest 设计：`reports/backup-retention-apply-manifest/BACKUP-RETENTION-APPLY-MANIFEST.md`
- `codex-account-switch` 依赖更新 dry-run：`reports/codex-account-switch-dependency-update-dry-run/PLAN.md`
- Codex 主机更新证据：`D:\Codex\.codex\run-evidence\codex-update-20260706-104516`
- 项目本地环境分类刷新：`.scratch/unified-env/issues/12-project-local-env-classification-refresh.md`
- `codex_switch` 安装回滚备份保留 dry-run：`.scratch/unified-env/issues/14-codex-switch-installed-backup-retention.md`
- 备份保留 apply 执行：`.scratch/unified-env/issues/15-backup-retention-apply-execution.md`
- `codex_switch` 旧式平铺备份文件删除：`.scratch/unified-env/issues/16-codex-switch-flat-backup-delete.md`
- 三类人工审查项删除：`.scratch/unified-env/issues/17-manual-review-cache-staging-backup-delete.md`

## 验证命令

```powershell
& 'D:\Codex\projects\统一环境\tests\Test-EnvInventory.ps1'
& 'D:\Codex\projects\统一环境\tests\Test-EnvMigrationPlan.ps1'
& 'D:\Codex\projects\统一环境\tests\Test-PipCacheMigration.ps1'
& 'D:\Codex\projects\统一环境\tests\Test-EnvUpdateReadiness.ps1'
& 'D:\Codex\projects\统一环境\tests\Test-StalePathEntryCleanupDryRun.ps1'
& 'D:\Codex\projects\统一环境\tests\Test-DDrivePolicyDocs.ps1'
& 'D:\Codex\projects\统一环境\tests\Test-ProjectLocalEnvReviewPack.ps1'
& 'D:\Codex\projects\统一环境\tests\Test-ProjectLocalEnvRebuildDryRunPlan.ps1'
& 'D:\Codex\projects\统一环境\tests\Test-BackupRetentionDryRun.ps1'
& 'D:\Codex\projects\统一环境\tests\Test-BackupRetentionApplyManifest.ps1'
```

## 安全边界

- 不自动迁移 `C:\Users`、`Program Files`、WindowsApps、凭据、浏览器 profile、数据库或服务状态。
- 不自动删除 C 盘旧源目录；删除需要单独显式授权。
- 不跨项目复用项目本地依赖目录。
- 不在 dirty repo 中更新依赖、锁文件或环境目录。
- 输出和证据必须留在 D 盘允许路径。
