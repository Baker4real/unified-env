# Issue 03：生成 dry-run 环境迁移计划

Status: done

## Parent

`.scratch/unified-env/PRD.md`

## What to build

基于只读 inventory 生成迁移计划，但不执行迁移。计划需要把每个迁移候选拆成来源、目标、风险、前置检查、执行步骤、验证步骤和回滚步骤。它应作为真实迁移前的安全闸。

## Acceptance criteria

- [x] 能从最新 inventory 读取迁移候选，而不是重新猜测环境状态。
- [x] 每个候选都有 dry-run 计划，包含目标位置、风险说明、验证方式和回滚方式。
- [x] 人工审查项和绝不自动迁移项不会进入可执行迁移计划。
- [x] 输出为中文 Markdown，适合用户审查。
- [x] 运行过程保持只读，不移动文件、不修改环境变量。

## Blocked by

- `.scratch/unified-env/issues/02-harden-readonly-inventory.md`

## Comments

覆盖 PRD 用户故事：13、19、20。

## Completion notes

- 新增 dry-run 迁移计划生成器，读取既有 inventory，不重新扫描环境。
- 输出 `reports/env-migration-plan/plan.json` 和 `reports/env-migration-plan/PLAN.md`。
- 每个计划项包含目标路径、风险、前置检查、执行步骤、验证步骤和回滚步骤。
- 人工审查项反向过滤，绝不进入 dry-run 计划。
- 命中 `C:\Users` 的具体缓存子目录仅生成 dry-run 候选，`executionAllowed=false`，真实执行必须显式授权。
- 增加 D 盘输出保护，阻止脚本把生成内容写到 C 盘。
- 补充 `tests/Test-EnvMigrationPlan.ps1` 覆盖计划契约、排除规则、root policy 和临时目录清理。
