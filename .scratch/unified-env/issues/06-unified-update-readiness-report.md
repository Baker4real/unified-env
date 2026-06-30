# Issue 06：生成统一更新准备报告

Status: ready-for-agent

## Parent

`.scratch/unified-env/PRD.md`

## What to build

基于 inventory 识别每个工具和运行时的推荐更新入口，生成统一更新准备报告。报告只做分类和建议，不执行更新。它需要区分可由包管理器更新、需官方安装器更新、需项目内更新、以及当前不应自动更新的对象。

## Acceptance criteria

- [ ] 报告列出已发现工具和运行时的当前入口。
- [ ] 每个对象都有推荐更新方式或“不要自动更新”的说明。
- [ ] 报告明确不会执行 `winget`、Scoop、uv、npm、Cargo、Rustup 或其他更新命令。
- [ ] 对 PATH 中的重复入口、C 盘入口和 D 盘入口给出整理建议。
- [ ] 高风险对象不会进入自动更新候选。

## Blocked by

- `.scratch/unified-env/issues/02-harden-readonly-inventory.md`

## Comments

覆盖 PRD 用户故事：1、4、21、22。
