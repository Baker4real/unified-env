# Issue 05：生成项目本地环境审查包

Status: ready-for-agent

## Parent

`.scratch/unified-env/PRD.md`

## What to build

为项目本地 `.venv`、`node_modules`、`.conda` 等环境生成逐项目审查包。审查包不迁移任何环境，只说明每个项目本地环境为何需要保留、是否可能重建、需要哪些项目级验证，以及后续是否值得单独开迁移或重建 issue。

## Acceptance criteria

- [ ] 从 inventory 的项目本地环境标记生成审查清单。
- [ ] 每个项目都有建议动作：保留、可重建、需项目 owner 决策或禁止自动处理。
- [ ] 报告明确项目本地环境默认不自动迁移。
- [ ] 对长期服务或高风险项目标出验证前置条件。
- [ ] 不移动、不删除、不合并任何项目本地环境。

## Blocked by

- `.scratch/unified-env/issues/02-harden-readonly-inventory.md`

## Comments

覆盖 PRD 用户故事：8、9、16。
