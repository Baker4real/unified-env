# Issue 07：沉淀 D 盘目标布局和迁移政策

Status: done

## Parent

`.scratch/unified-env/PRD.md`

## What to build

把本项目的 D 盘目标布局和迁移政策沉淀成后续 agent 必读文档。文档要明确哪些内容可以共享、哪些必须项目隔离、哪些只能人工审查、哪些绝不自动迁移，以及每类对象迁移前必须满足的授权、回滚和验证要求。

## Acceptance criteria

- [x] 文档定义推荐的 D 盘根：工具、共享环境、缓存、报告和迁移证据。
- [x] 文档定义环境分类：共享运行时、共享缓存、全局 CLI、项目本地环境、人工审查项、绝不自动迁移项。
- [x] 文档说明项目本地 `.venv` 和 `node_modules` 默认保留隔离。
- [x] 文档说明真实迁移必须有 dry-run、显式授权、验证和回滚。
- [x] 文档被项目代理说明或 domain docs 指向，便于后续 agent 执行前读取。

## Blocked by

- `.scratch/unified-env/issues/02-harden-readonly-inventory.md`

## Comments

覆盖 PRD 用户故事：10、11、18、22。

## Completion notes

- 新增 `docs/env-governance/d-drive-layout-and-migration-policy.md`，沉淀 D 盘目标布局、环境分类、禁止迁移项、迁移门槛和执行顺序。
- 新增 `CONTEXT.md`，说明本项目目标、核心原则和当前事实基线报告。
- 更新 `AGENTS.md`，要求真实迁移前先读取 D 盘布局与迁移政策。
- 新增 `tests/Test-DDrivePolicyDocs.ps1`，验证文档入口和核心政策文本存在。
- 安全审查后收紧政策：旧源目录默认保留，删除、清理或 C 盘配置写入必须单独显式授权；来源、目标、输出路径及其已存在父级都不能穿过 junction、symlink 或 reparse point。
