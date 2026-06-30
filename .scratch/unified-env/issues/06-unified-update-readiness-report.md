# Issue 06：生成统一更新准备报告

Status: done

## Parent

`.scratch/unified-env/PRD.md`

## What to build

基于 inventory 识别每个工具和运行时的推荐更新入口，生成统一更新准备报告。报告只做分类和建议，不执行更新。它需要区分可由包管理器更新、需官方安装器更新、需项目内更新、以及当前不应自动更新的对象。

## Acceptance criteria

- [x] 报告列出已发现工具和运行时的当前入口。
- [x] 每个对象都有推荐更新方式或“不要自动更新”的说明。
- [x] 报告明确不会执行 `winget`、Scoop、uv、npm、Cargo、Rustup 或其他更新命令。
- [x] 对 PATH 中的重复入口、C 盘入口和 D 盘入口给出整理建议。
- [x] 高风险对象不会进入自动更新候选。

## Blocked by

- `.scratch/unified-env/issues/02-harden-readonly-inventory.md`

## Comments

覆盖 PRD 用户故事：1、4、21、22。

## Completion notes

- 生成只读更新准备报告：`reports/env-update-readiness/readiness.json` 和 `reports/env-update-readiness/REPORT.md`。
- 当前正式报告识别 13 个工具入口、2 个高风险对象、0 个自动更新候选；高风险对象为 `dotnet` 和 `wsl`。
- `OutputDir` 仅允许 D 盘目录，并阻止穿过 junction、symlink 或 reparse point 的输出路径。
- Markdown 报告使用中文展示位置类型、风险等级和“不自动更新”状态；JSON 保留稳定机器可读字段。
- 已运行 `tests/Test-EnvInventory.ps1`、`tests/Test-EnvMigrationPlan.ps1`、`tests/Test-EnvUpdateReadiness.ps1`。
- 已完成双子代理复核：需求验收和安全边界均无剩余阻塞问题。
