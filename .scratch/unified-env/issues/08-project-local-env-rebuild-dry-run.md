# Issue 08：生成项目本地环境重建 dry-run 计划

Status: done

## Parent

`.scratch/unified-env/PRD.md`

## What to build

基于 `reports/project-local-env-review/review.json` 生成逐项目重建 dry-run 计划。该计划只描述后续如果要重建项目本地 `.venv`、`node_modules` 或类似环境时需要满足的前置条件、候选命令、验证步骤、回滚边界和人工决策门。

本 issue 不执行任何重建、不移动、不删除、不合并任何项目本地环境。

## Acceptance criteria

- [x] 从项目本地环境审查包生成计划项，不能扫描出一套不一致的项目集合。
- [x] 每个审查项都有计划状态：可计划重建、需 owner 决策或禁止自动处理。
- [x] 有重建线索的项目只输出候选命令预览，不执行命令，且 `executionAllowed=false`。
- [x] 高风险、长期服务或状态敏感项目必须标出人工决策门、停机窗口、健康检查和回滚前置条件。
- [x] 缺锁文件或缺说明的项目不得输出可直接执行的重建命令。
- [x] 输出 JSON 和 Markdown 报告，并明确 dry-run、不执行、不删除、不迁移。
- [x] 不移动、不删除、不重建任何项目本地环境。

## Blocked by

- `.scratch/unified-env/issues/05-project-local-env-review-pack.md`

## Comments

延续统一环境目标：尽量复用事实和计划，但项目本地环境默认不做跨项目复用或自动重建。

## Completion notes

- 新增 `scripts/New-ProjectLocalEnvRebuildDryRunPlan.ps1`，从 `reports/project-local-env-review/review.json` 生成逐项目重建 dry-run 计划。
- 正式产物：
  - `reports/project-local-env-rebuild-plan/plan.json`
  - `reports/project-local-env-rebuild-plan/PLAN.md`
- 当前计划项：5 项；可计划重建：1 项；需 owner 决策：5 项；缺少重建来源阻塞：1 项；高风险或状态敏感：3 项。
- 只有 `D:\Codex\projects\codex-account-switch\node_modules` 因 `package-lock.json` 输出 `npm ci` 候选命令预览；命令不执行，`executionAllowed=false`。
- `requirements.txt` 不是锁文件；`yangyangzi-direct-qqbot` 不再输出 `pip install` 或 `python -m venv` 候选命令。
- 高风险或长期服务项目进入 `owner-decision-required` 或 `blocked-no-rebuild-source`，必须先确认 owner、停机窗口、健康检查和回滚前置条件。
- 输出和来源路径均做 D 盘、允许目录、junction/symlink/reparse point 边界检查。
- 验证通过：
  - `tests/Test-ProjectLocalEnvRebuildDryRunPlan.ps1`
  - `tests/Test-ProjectLocalEnvReviewPack.ps1`
  - `tests/Test-EnvInventory.ps1`
  - `tests/Test-EnvMigrationPlan.ps1`
  - `tests/Test-PipCacheMigration.ps1`
  - `tests/Test-EnvUpdateReadiness.ps1`
  - `tests/Test-DDrivePolicyDocs.ps1`
- 已启用两个子代理做只读对抗性审查；初次审查发现的 `requirements.txt` 命令、测试 reparse guard、ReviewPath guard 和高风险状态误读问题已修复并复测。
- 增量复核无 P0/P1；剩余测试父级 reparse guard P2 已补齐并复测。
