# Issue 13：失效 PATH 入口清理 dry-run

Status: done

## Parent

`.scratch/unified-env/PRD.md`

## What to build

基于更新准备报告里的失效项目本地环境 PATH 入口，生成独立的只读清理 dry-run。

本 issue 只生成清理候选、前置检查、验证步骤、回滚步骤和人工授权门；不修改用户 PATH，不写注册表或系统配置，不删除、不移动、不重建任何 `.venv`、`node_modules` 或项目目录。

## Acceptance criteria

- [x] 从 `reports/env-update-readiness/readiness.json` 读取 `staleLocalEnvironmentEntries`。
- [x] 对每个 PATH 候选二次确认当前路径是否存在；已存在路径必须进入阻塞状态。
- [x] 输出 `executionAllowed=false`、`pathMutationAllowed=false`、`registryWriteAllowed=false`、`deleteAllowed=false`。
- [x] 报告明确真实清理只能在用户逐项确认 candidateId、路径数量和具体 PATH 字符串后执行。
- [x] 报告明确真实清理只允许移除 PATH 字符串，不触碰环境目录。
- [x] 测试覆盖只读策略、输出目录守卫、阻塞候选、Markdown 报告和禁止危险命令文本。

## Completion notes

- 正式 dry-run：
  - `reports/stale-path-entry-cleanup-dry-run/plan.json`
  - `reports/stale-path-entry-cleanup-dry-run/PLAN.md`
- 当前候选数量：1
- 当前可进入真实授权候选：1
- 当前候选路径：`D:\hermes-agent\.venv\Scripts`
- 当前执行状态：不允许执行；真实 PATH 修改仍需单独显式授权。

## Verification

- `tests/Test-StalePathEntryCleanupDryRun.ps1`

## Follow-up

如后续要真实清理 PATH，必须先重新生成 `env-update-readiness` 和本 dry-run，确认候选仍然存在且数量不变，再由用户逐项授权。真实清理应作为独立步骤执行，并保留清理前完整 User scope PATH 字符串用于回滚。
