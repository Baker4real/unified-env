# 统一环境治理

本项目用于治理本机开发环境：先只读盘点事实，再生成 dry-run 计划，最后只在明确授权下逐项迁移、更新或重建。

核心原则：该共享的共享，该隔离的隔离。共享缓存和可复用工具入口优先放到 D 盘；项目本地 `.venv`、`node_modules`、服务状态和凭据目录默认保持隔离。

## 当前能力

- 可信环境治理报告链分别记录 Process、User、Machine PATH，并用 `generationId` 和源 JSON SHA-256 配对校验当前 JSON/Markdown 产物。
- 环境迁移、项目本地环境重建、备份保留和依赖更新均先生成 dry-run；真实迁移、更新或删除仍需对具体项显式授权。
- 备份保留 apply 受 schema、覆盖完整性、候选一致性和 manifest 安全门约束，不从过期报告推断可执行动作。
- Codex 主机钩子治理以“用户级自定义 lifecycle hook 为 0”为目标；静态状态由显式冷路径 reconciler 维护，Serena 中性启动并按当前 workspace 显式激活。

## 关键入口

- 项目上下文：`CONTEXT.md`
- 迁移政策：`docs/env-governance/d-drive-layout-and-migration-policy.md`
- Codex 主机钩子治理：`docs/specs/2026-07-11-host-hook-reconciliation-design.md`
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

从仓库根目录使用 PowerShell 7.6+ 运行全部测试：

```powershell
$tests = Get-ChildItem -LiteralPath '.\tests' -Filter 'Test-*.ps1' -File | Sort-Object Name
foreach ($test in $tests) {
    & ([Environment]::ProcessPath) -NoProfile -File $test.FullName
    if ($LASTEXITCODE -ne 0) {
        throw "$($test.Name) 失败，退出码：$LASTEXITCODE"
    }
}
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
