# 统一环境治理

本项目用于治理本机开发环境：先只读盘点事实，再生成 dry-run 计划，最后只在明确授权下逐项迁移、更新或重建。

核心原则：该共享的共享，该隔离的隔离。共享缓存和可复用工具入口优先放到 D 盘；项目本地 `.venv`、`node_modules`、服务状态和凭据目录默认保持隔离。

## 当前状态

- 已迁移低风险 `pip cache` 到 `D:\Codex\.cache\pip`。
- 当前没有新的明确安全迁移候选。
- 项目本地环境已完成审查和重建 dry-run 计划；真实重建仍需 owner 决策。
- 下一步建议从 `codex-account-switch` 的依赖更新 dry-run 开始，而不是直接运行 `npm ci`。

## 关键入口

- 项目上下文：`CONTEXT.md`
- 迁移政策：`docs/env-governance/d-drive-layout-and-migration-policy.md`
- 本地 issue：`.scratch/unified-env/issues/`
- 交接文档：`docs/handoffs/`

## 主要报告

- 只读盘点：`reports/env-inventory/REPORT.md`
- 迁移 dry-run：`reports/env-migration-plan/PLAN.md`
- pip cache 迁移证据：`reports/env-migration-execution/pip-cache/`
- 更新准备：`reports/env-update-readiness/REPORT.md`
- 项目本地环境审查：`reports/project-local-env-review/REPORT.md`
- 项目本地环境重建 dry-run：`reports/project-local-env-rebuild-plan/PLAN.md`

## 验证命令

```powershell
& 'D:\Codex\projects\统一环境\tests\Test-EnvInventory.ps1'
& 'D:\Codex\projects\统一环境\tests\Test-EnvMigrationPlan.ps1'
& 'D:\Codex\projects\统一环境\tests\Test-PipCacheMigration.ps1'
& 'D:\Codex\projects\统一环境\tests\Test-EnvUpdateReadiness.ps1'
& 'D:\Codex\projects\统一环境\tests\Test-DDrivePolicyDocs.ps1'
& 'D:\Codex\projects\统一环境\tests\Test-ProjectLocalEnvReviewPack.ps1'
& 'D:\Codex\projects\统一环境\tests\Test-ProjectLocalEnvRebuildDryRunPlan.ps1'
```

## 安全边界

- 不自动迁移 `C:\Users`、`Program Files`、WindowsApps、凭据、浏览器 profile、数据库或服务状态。
- 不自动删除 C 盘旧源目录；删除需要单独显式授权。
- 不跨项目复用项目本地依赖目录。
- 不在 dirty repo 中更新依赖、锁文件或环境目录。
- 输出和证据必须留在 D 盘允许路径。
