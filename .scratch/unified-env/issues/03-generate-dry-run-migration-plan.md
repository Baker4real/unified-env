# Issue 03：生成 dry-run 环境迁移计划

Status: ready-for-agent

## Parent

`.scratch/unified-env/PRD.md`

## What to build

基于只读 inventory 生成迁移计划，但不执行迁移。计划需要把每个迁移候选拆成来源、目标、风险、前置检查、执行步骤、验证步骤和回滚步骤。它应作为真实迁移前的安全闸。

## Acceptance criteria

- [ ] 能从最新 inventory 读取迁移候选，而不是重新猜测环境状态。
- [ ] 每个候选都有 dry-run 计划，包含目标位置、风险说明、验证方式和回滚方式。
- [ ] 人工审查项和绝不自动迁移项不会进入可执行迁移计划。
- [ ] 输出为中文 Markdown，适合用户审查。
- [ ] 运行过程保持只读，不移动文件、不修改环境变量。

## Blocked by

- `.scratch/unified-env/issues/02-harden-readonly-inventory.md`

## Comments

覆盖 PRD 用户故事：13、19、20。
