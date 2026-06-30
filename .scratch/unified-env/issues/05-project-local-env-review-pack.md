# Issue 05：生成项目本地环境审查包

Status: done

## Parent

`.scratch/unified-env/PRD.md`

## What to build

为项目本地 `.venv`、`node_modules`、`.conda` 等环境生成逐项目审查包。审查包不迁移任何环境，只说明每个项目本地环境为何需要保留、是否可能重建、需要哪些项目级验证，以及后续是否值得单独开迁移或重建 issue。

## Acceptance criteria

- [x] 从 inventory 的项目本地环境标记生成审查清单。
- [x] 每个项目都有建议动作：保留、可重建、需项目 owner 决策或禁止自动处理。
- [x] 报告明确项目本地环境默认不自动迁移。
- [x] 对长期服务或高风险项目标出验证前置条件。
- [x] 不移动、不删除、不合并任何项目本地环境。

## Blocked by

- `.scratch/unified-env/issues/02-harden-readonly-inventory.md`

## Comments

覆盖 PRD 用户故事：8、9、16。

## Completion notes

- 新增 `scripts/New-ProjectLocalEnvReviewPack.ps1`，从 `reports/env-inventory/inventory.json` 的 `projectEnvironmentMarkers` 生成只读审查包。
- 正式产物：
  - `reports/project-local-env-review/review.json`
  - `reports/project-local-env-review/REPORT.md`
- 当前审查项：5 项；长期服务或状态敏感项目：3 项；可重建线索项：3 项；允许自动处理项：0 项。
- 输出安全边界：只允许写入项目 `reports` 或 `D:\Codex\.codex\run-evidence\env-governance`，并拒绝穿过 junction、symlink 或 reparse point 的输出路径/既有输出文件。
- 验证通过：
  - `tests/Test-ProjectLocalEnvReviewPack.ps1`
  - `tests/Test-EnvInventory.ps1`
  - `tests/Test-EnvMigrationPlan.ps1`
  - `tests/Test-PipCacheMigration.ps1`
  - `tests/Test-EnvUpdateReadiness.ps1`
  - `tests/Test-DDrivePolicyDocs.ps1`
- 已启用两个子代理做只读审查：安全边界审查发现的输出文件 reparse 缺口已修复；验收审查无 P0/P1 阻塞，提出的 P2 测试盲点已补强。
