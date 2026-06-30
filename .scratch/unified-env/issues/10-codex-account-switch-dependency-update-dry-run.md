# Issue 10：生成 codex-account-switch 依赖更新 dry-run

Status: done

## Parent

`.scratch/unified-env/PRD.md`

## What to build

基于 `D:\Codex\projects\codex-account-switch` 的当前 `package.json`、`package-lock.json`、`npm ls`、`npm outdated`、`npm audit` 和 git 状态，生成项目级依赖更新 dry-run 计划。

本 issue 只生成计划和报告，不修改 `D:\Codex\projects\codex-account-switch`，不执行 `npm install`、`npm ci`、`npm audit fix` 或任何依赖更新命令。

## Acceptance criteria

- [x] 重新查询目标项目当前 npm 事实，不复用 handoff 里的旧版本判断作为执行依据。
- [x] 输出 JSON 和 Markdown 报告，且明确 `dryRun=true`、`readOnly=true`、`executionAllowed=false`、`deleteAllowed=false`、`migrationAllowed=false`。
- [x] 报告必须写入 `D:\Codex\projects\统一环境\reports\` 或 `D:\Codex\.codex\run-evidence\env-governance\` 下，不写入 C 盘。
- [x] 当前更新建议聚焦安全补丁优先，尤其是 `vite` 的 npm audit fix 版本；不得直接建议跳到 `vite 8` 或 `typescript 6`。
- [x] 明确说明 `npm ci` 只能重建当前锁定依赖，不能让依赖保持最新。
- [x] 如果目标项目 dirty，报告必须把真实更新标为阻塞；如果当前 clean，也要保留执行前重新检查 dirty 状态的 gate。
- [x] 候选真实命令只能作为预览，例如 `npm install vite@<audit-fix-version> --save-dev --package-lock-only --ignore-scripts`，不得在本 issue 中执行。
- [x] 验证命令预览至少包含 `npm ls --depth=0`、`npm audit`、`npm run version:check`，并标出必要时的 Windows 项目验证。
- [x] 回滚边界必须限定在恢复 `package.json` 和 `package-lock.json`，不得删除现有 `node_modules`。
- [x] 有测试覆盖：阻止 C 盘输出、阻止非授权 D 盘输出、dirty worktree 阻塞、候选命令仅为预览、报告包含暂不升级 `vite 8` / `typescript 6` 的理由。

## Blocked by

- `.scratch/unified-env/issues/08-project-local-env-rebuild-dry-run.md`
- `docs/env-governance/d-drive-layout-and-migration-policy.md`

## Comments

本 issue 不包含真实依赖更新授权。后续若要更新 `codex-account-switch`，必须由用户确认目标项目 dirty 状态、更新范围、验证命令和回滚边界；笼统的“继续”不等于执行依赖更新。

## Completion notes

- 新增 `scripts/New-CodexAccountSwitchDependencyUpdateDryRun.ps1`，只读查询目标项目的 package、lockfile、git、Node/npm、`npm ls`、`npm outdated` 和 `npm audit`。
- 正式产物：
  - `reports/codex-account-switch-dependency-update-dry-run/plan.json`
  - `reports/codex-account-switch-dependency-update-dry-run/PLAN.md`
- 当前目标项目 `D:\Codex\projects\codex-account-switch` 的 `git status --short --branch` 为 clean，分支为 `codex/clean-codex-switch-local-patches`；真实执行前仍必须重新检查。
- 当前 npm 事实：
  - `@tauri-apps/api`：`2.10.1 -> latest 2.11.1`
  - `@tauri-apps/cli`：`2.10.1 -> latest 2.11.4`
  - `typescript`：`5.9.2 -> latest 6.0.3`
  - `vite`：`7.1.4 -> latest 8.1.2`
- 当前 `npm audit`：`postcss` transitive moderate，`vite` direct high；`vite` fixAvailable 为 `7.3.6`。
- 推荐仍停在 owner review：候选命令只是 `npm install vite@7.3.6 --save-dev --package-lock-only --ignore-scripts` 预览，未执行。
- 验证通过：
  - `tests/Test-CodexAccountSwitchDependencyUpdateDryRun.ps1`
  - `tests/Test-ProjectLocalEnvRebuildDryRunPlan.ps1`
  - `tests/Test-ProjectLocalEnvReviewPack.ps1`
  - `tests/Test-EnvMigrationPlan.ps1`
  - `tests/Test-PipCacheMigration.ps1`
  - `tests/Test-EnvUpdateReadiness.ps1`
  - `tests/Test-DDrivePolicyDocs.ps1`
  - `tests/Test-EnvInventory.ps1`
