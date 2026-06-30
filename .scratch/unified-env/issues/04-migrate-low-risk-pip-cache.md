# Issue 04：迁移低风险 pip cache 候选

Status: done

## Parent

`.scratch/unified-env/PRD.md`

## What to build

在 dry-run 计划通过后，只处理当前低风险 pip cache 候选。该切片要完成真实迁移、环境变量切换、迁移前后验证和回滚验证。不得顺手处理其他缓存、运行时或项目本地环境。

## Acceptance criteria

- [x] 执行前有明确 dry-run 计划，并确认只覆盖 pip cache。
- [x] 迁移前记录源目录状态和目标目录状态。
- [x] 迁移后 pip 使用 D 盘缓存位置。
- [x] 迁移后盘点报告不再把旧默认 pip cache 作为未处理低风险候选。
- [x] 回滚步骤可执行，并能恢复到迁移前策略。
- [x] 不迁移项目本地 `.venv` 或其他人工审查项。

## Blocked by

- `.scratch/unified-env/issues/03-generate-dry-run-migration-plan.md`

## Comments

覆盖 PRD 用户故事：6、7、19、20。

## Completion notes

- 已执行授权迁移项 `migration-01-python-cache`：`C:\Users\14224\AppData\Local\pip\Cache` -> `D:\Codex\.cache\pip`。
- 执行采用非破坏性复制：复制 266 个缺失文件，跳过 9 个目标已存在文件；旧 C 盘源目录保留，未删除。
- User scope `PIP_CACHE_DIR` 已从 `D:\Codex\.pip-cache` 切换为 `D:\Codex\.cache\pip`。
- 当前默认 Python 没有 `pip` 模块，PATH 中也没有 `pip/pip3` 命令，因此运行时验证以 User scope 环境变量和 post inventory/plan 为准；旧长生命周期进程需要刷新或重启后读取新的 User 环境。
- 迁移后 `reports/env-inventory` 中迁移候选为 0，`reports/env-migration-plan` 中可计划迁移项为 0。
- 回滚状态和命令见 `reports/env-migration-execution/pip-cache/rollback-state.json` 与 `reports/env-migration-execution/pip-cache/EXECUTION.md`。
- 已运行 `tests/Test-PipCacheMigration.ps1`、`tests/Test-EnvInventory.ps1`、`tests/Test-EnvMigrationPlan.ps1`、`tests/Test-EnvUpdateReadiness.ps1`、`tests/Test-DDrivePolicyDocs.ps1`。
- 已完成双子代理复核：需求验收和迁移安全均无剩余阻塞问题。
