# 统一环境治理

本项目用于治理本机开发环境：先只读盘点事实，再生成 dry-run 计划，最后只在明确授权下逐项迁移、更新或重建。

核心原则：该共享的共享，该隔离的隔离。共享缓存和可复用工具入口优先放到 D 盘；项目本地 `.venv`、`node_modules`、服务状态和凭据目录默认保持隔离。

## 当前状态

- 已重建可信环境治理报告链：inventory 为 schema 3，分别记录 Process、User、Machine PATH；readiness 为 schema 3；本次重建的当前 JSON/Markdown 报告对均带 `generationId` 和源 JSON SHA-256 校验信息。
- 当前生产备份保留 dry-run 为 schema 2，覆盖已计账但不完整（`coverageComplete=false`），真实候选为 0；apply 安全门已验证拒绝，因此当前没有可发布的 schema 2 apply manifest。仓库中的旧 schema 1 manifest 快照已移除；这不涉及删除任何备份源数据。
- 当前没有新的明确安全迁移候选。
- 项目本地环境已完成分类刷新、审查和重建 dry-run 计划；当前区分项目根环境、嵌套 app、插件 runtime/cache、repair backup 和归档缓存，真实重建仍需 owner 决策。
- 已按授权从 User scope PATH 移除失效项目本地环境入口 `D:\hermes-agent\.venv\Scripts`；最新 PATH 清理 dry-run 候选为 0。
- 已新增备份膨胀治理 dry-run 脚本，当前只读报告把严格保留规则候选和人工审查项分开，并已纳入 `codex_switch` 安装回滚备份；真实清理仍需显式授权。
- 历史备份清理动作保留在本地 issue 15–17 和 Git 历史中；当前是否可清理只以 schema 2 生产 dry-run 为准，目前覆盖不完整、候选为 0。
- 已完成 `codex-account-switch` 依赖更新 dry-run；当前安全补丁已满足，后续框架 minor 或大版本更新仍需在目标项目中显式授权。
- 已完成 2026-07-06 Codex 主机更新收尾：Codex CLI、Node、npm、Git、gh、uv、sqlite3、CodeGraph 和 Serena 主链路已验证；Serena 运行在官方 Python 3.14.6 上，并通过 uv override 使用 `anthropic==0.116.0`。
- 已完成 2026-07-06 环境更新执行：`planning-with-files` 已更新并保留本地 overlay，skill ledger coverage 为 `missing=0` / `duplicates=0`；CMake 默认入口为 D 盘 `4.3.3`，Rust 默认 toolchain 为 `1.96.1`。
- 已按用户授权修复默认入口：`.NET` 默认命中 D 盘 SDK `10.0.301`，Python 默认切到官方 `3.14.6`；WSL 当前判断为“不确实需要”，未安装、未启用、未初始化；CodeGraph 已确认 latest 仍为 `1.2.0`。

## 关键入口

- 项目上下文：`CONTEXT.md`
- 迁移政策：`docs/env-governance/d-drive-layout-and-migration-policy.md`
- 本地 issue：`.scratch/unified-env/issues/`
- 可信盘点设计：`docs/specs/2026-07-10-environment-inventory-trust-design.md`
- 可信盘点实施计划：`docs/plans/2026-07-10-environment-inventory-trust-implementation.md`
- 环境更新执行报告：`reports/env-update-execution-20260706/REPORT.md`

## 主要报告

- 只读盘点：`reports/env-inventory/REPORT.md`
- 迁移 dry-run：`reports/env-migration-plan/PLAN.md`
- pip cache 迁移证据：`reports/env-migration-execution/pip-cache/`
- 更新准备：`reports/env-update-readiness/REPORT.md`
- 失效 PATH 入口清理 dry-run：`reports/stale-path-entry-cleanup-dry-run/PLAN.md`
- 项目本地环境审查：`reports/project-local-env-review/REPORT.md`
- 项目本地环境重建 dry-run：`reports/project-local-env-rebuild-plan/PLAN.md`
- 当前备份膨胀治理 dry-run：`reports/backup-retention-dry-run-current/BACKUP-RETENTION-DRY-RUN.md`
- 备份清理 apply manifest：当前没有可发布的 schema 2 manifest；生产 dry-run 覆盖不完整，安全门已拒绝生成。
- `codex-account-switch` 依赖更新 dry-run：`reports/codex-account-switch-dependency-update-dry-run/PLAN.md`
- 项目本地环境分类刷新：`.scratch/unified-env/issues/12-project-local-env-classification-refresh.md`
- `codex_switch` 安装回滚备份保留 dry-run：`.scratch/unified-env/issues/14-codex-switch-installed-backup-retention.md`
- 备份保留 apply 执行：`.scratch/unified-env/issues/15-backup-retention-apply-execution.md`
- `codex_switch` 旧式平铺备份文件删除：`.scratch/unified-env/issues/16-codex-switch-flat-backup-delete.md`
- 三类人工审查项删除：`.scratch/unified-env/issues/17-manual-review-cache-staging-backup-delete.md`

## 验证命令

```powershell
& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\Codex\projects\统一环境\tests\Test-ReportArtifactPublisher.ps1'
& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\Codex\projects\统一环境\tests\Test-EnvInventoryTrust.ps1'
& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\Codex\projects\统一环境\tests\Test-EnvInventory.ps1'
& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\Codex\projects\统一环境\tests\Test-EnvMigrationPolicy.ps1'
& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\Codex\projects\统一环境\tests\Test-EnvMigrationPlan.ps1'
& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\Codex\projects\统一环境\tests\Test-PipCacheMigration.ps1'
& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\Codex\projects\统一环境\tests\Test-EnvUpdateReadinessPolicy.ps1'
& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\Codex\projects\统一环境\tests\Test-EnvUpdateReadiness.ps1'
& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\Codex\projects\统一环境\tests\Test-StalePathEntryCleanupDryRun.ps1'
& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\Codex\projects\统一环境\tests\Test-DDrivePolicyDocs.ps1'
& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\Codex\projects\统一环境\tests\Test-ProjectLocalEnvReviewPack.ps1'
& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\Codex\projects\统一环境\tests\Test-ProjectLocalEnvRebuildDryRunPlan.ps1'
& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\Codex\projects\统一环境\tests\Test-BackupRetentionPolicy.ps1'
& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\Codex\projects\统一环境\tests\Test-BackupRetentionDryRun.ps1'
& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\Codex\projects\统一环境\tests\Test-BackupRetentionValidation.ps1'
& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\Codex\projects\统一环境\tests\Test-BackupRetentionApplyManifest.ps1'
& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\Codex\projects\统一环境\tests\Test-CodexAccountSwitchDependencyUpdateDryRun.ps1'
```

## 安全边界

- 不自动迁移 `C:\Users`、`Program Files`、WindowsApps、凭据、浏览器 profile、数据库或服务状态。
- 不自动删除 C 盘旧源目录；删除需要单独显式授权。
- 不跨项目复用项目本地依赖目录。
- 不在 dirty repo 中更新依赖、锁文件或环境目录。
- 输出和证据必须留在 D 盘允许路径。

## Git 分支策略

- 本项目是独立私有治理仓库，不是第三方上游的本地补丁栈仓库。
- 不维护 `patch-stack/*` 远端分支；回滚和审计以 `main` 的普通 Git 历史、报告和证据目录为准。
- 只有名称或职责明确为 `*-local-patches` 的私有补丁栈仓库才使用 `patch-stack/*`。
