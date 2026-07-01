# Issue 12：刷新项目本地环境分类口径

Status: done

## Parent

`.scratch/unified-env/PRD.md`

## What to build

扩展只读 inventory、项目本地环境审查包、重建 dry-run 和更新准备报告，让它们能区分：

- 项目根本地环境。
- 嵌套 app 本地环境。
- 插件 runtime/cache 里的 `node_modules`。
- repair backup 里的插件缓存副本。
- 文档或历史归档里的依赖缓存副本。
- 失效的项目本地环境 PATH 入口。

本 issue 不执行迁移、不删除目录、不重建 `.venv` / `node_modules`，也不修改用户 PATH。

## Acceptance criteria

- [x] `Invoke-EnvInventory.ps1` 递归发现相关 `.venv`、`venv`、`node_modules`、`.conda`，并输出分类字段。
- [x] `projectEnvironmentMarkers` 只包含可进入项目级审查的项目根或嵌套 app 环境。
- [x] `localEnvironmentFindings` 保留全部相关发现，包括插件 runtime/cache、repair backup 和归档缓存。
- [x] 插件 runtime/cache、repair backup 和归档缓存不得进入项目本地环境 rebuild 计划。
- [x] `codex-plus-plus/apps/codex-plus-manager/node_modules` 作为嵌套 app 本地环境进入项目级审查，但因 GSD/状态敏感边界停在 owner 决策。
- [x] `D:\hermes-agent\.venv\Scripts` 作为失效项目本地环境 PATH 入口进入只读更新准备报告，但不生成 PATH 修改命令。
- [x] 测试覆盖分类、防误入重建计划、失效 PATH 入口和报告文本。

## Completion notes

- 正式 inventory：
  - `reports/env-inventory/inventory.json`
  - `reports/env-inventory/REPORT.md`
- 当前正式 inventory 摘要：
  - 本地环境相关发现：11
  - 项目级审查环境：6
  - 人工审查项：11
- 正式项目本地环境审查：
  - `reports/project-local-env-review/review.json`
  - `reports/project-local-env-review/REPORT.md`
  - 当前审查项：6
  - 嵌套 app 环境项：1
- 正式项目本地环境重建 dry-run：
  - `reports/project-local-env-rebuild-plan/plan.json`
  - `reports/project-local-env-rebuild-plan/PLAN.md`
  - 当前计划项：6
  - 所有计划仍为 `executionAllowed=false`
- 正式更新准备报告：
  - `reports/env-update-readiness/readiness.json`
  - `reports/env-update-readiness/REPORT.md`
  - 失效项目本地环境 PATH 入口：1，当前为 `D:\hermes-agent\.venv\Scripts`

## Verification

- `tests/Test-EnvInventory.ps1`
- `tests/Test-EnvUpdateReadiness.ps1`
- `tests/Test-ProjectLocalEnvReviewPack.ps1`
- `tests/Test-ProjectLocalEnvRebuildDryRunPlan.ps1`
- `tests/Test-EnvMigrationPlan.ps1`

## Follow-up

后续若要处理失效 PATH 入口，应单独生成 PATH 清理 dry-run，并在用户明确授权后再修改用户环境变量。不得把 PATH 清理和依赖目录重建、删除混在一起。
