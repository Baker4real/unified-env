# Issue 04：迁移低风险 pip cache 候选

Status: ready-for-agent

## Parent

`.scratch/unified-env/PRD.md`

## What to build

在 dry-run 计划通过后，只处理当前低风险 pip cache 候选。该切片要完成真实迁移、环境变量切换、迁移前后验证和回滚验证。不得顺手处理其他缓存、运行时或项目本地环境。

## Acceptance criteria

- [ ] 执行前有明确 dry-run 计划，并确认只覆盖 pip cache。
- [ ] 迁移前记录源目录状态和目标目录状态。
- [ ] 迁移后 pip 使用 D 盘缓存位置。
- [ ] 迁移后盘点报告不再把旧默认 pip cache 作为未处理低风险候选。
- [ ] 回滚步骤可执行，并能恢复到迁移前策略。
- [ ] 不迁移项目本地 `.venv` 或其他人工审查项。

## Blocked by

- `.scratch/unified-env/issues/03-generate-dry-run-migration-plan.md`

## Comments

覆盖 PRD 用户故事：6、7、19、20。
