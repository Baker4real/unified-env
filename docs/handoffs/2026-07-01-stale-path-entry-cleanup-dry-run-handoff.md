# 失效 PATH 入口清理 dry-run 交接

生成时间：2026-07-01 13:45 +08:00

## 当前结论

本轮只完成失效 PATH 入口清理 dry-run，没有修改用户 PATH、没有写注册表或系统配置，也没有删除、移动或重建任何 `.venv`、`node_modules` 或项目目录。

当前状态：

- 已提交：`530870d feat: 生成失效 PATH 入口清理 dry-run`
- 正式 dry-run：`D:\Codex\projects\统一环境\reports\stale-path-entry-cleanup-dry-run\PLAN.md`
- 机器可读计划：`D:\Codex\projects\统一环境\reports\stale-path-entry-cleanup-dry-run\plan.json`
- Issue：`D:\Codex\projects\统一环境\.scratch\unified-env\issues\13-stale-path-entry-cleanup-dry-run.md`
- 候选数量：1
- 可进入真实授权候选：1
- 阻塞候选：0
- `executionAllowed=false`
- `pathMutationAllowed=false`
- `deleteAllowed=false`

## 必读文件

- 项目说明：`D:\Codex\projects\统一环境\README.md`
- 当前上下文：`D:\Codex\projects\统一环境\CONTEXT.md`
- 迁移政策：`D:\Codex\projects\统一环境\docs\env-governance\d-drive-layout-and-migration-policy.md`
- Issue 13：`D:\Codex\projects\统一环境\.scratch\unified-env\issues\13-stale-path-entry-cleanup-dry-run.md`
- 更新准备报告：`D:\Codex\projects\统一环境\reports\env-update-readiness\REPORT.md`
- PATH 清理 dry-run：`D:\Codex\projects\统一环境\reports\stale-path-entry-cleanup-dry-run\PLAN.md`

## 候选事实

当前唯一候选：

- candidateId：`stale-path-23-97cda33deb43`
- PATH 序号：23
- 路径：`D:\hermes-agent\.venv\Scripts`
- 当前存在：否
- 状态：`cleanup-candidate`
- 建议动作：真实授权后只从用户 PATH 中移除该失效入口；不删除、不重建对应环境目录。

## 安全边界

- dry-run 不是执行授权。
- 真实清理前必须重新生成 `env-update-readiness` 和本 dry-run。
- 真实清理前必须由用户逐项确认 candidateId、路径数量和具体 PATH 字符串。
- 真实清理只能处理 PATH 字符串，不能触碰 `.venv`、`node_modules`、项目文件或目录。
- 真实清理必须保留清理前完整 User scope PATH 字符串，用于按原顺序回滚。
- 真实清理必须作为独立步骤执行，不能和依赖重建、目录删除或环境迁移合并。

## 验证记录

已通过：

- `tests\Test-StalePathEntryCleanupDryRun.ps1`
- 全套 11 个项目测试
- `git diff --check`
- `git diff --cached --check`

额外审查：

- `scripts\New-StalePathEntryCleanupDryRun.ps1` 中未匹配到 `SetEnvironmentVariable`、`Set-ItemProperty`、`setx`、`reg add`、`Remove-Item`、`Move-Item`。
- `plan.json` 保持 `dryRun=true`、`readOnly=true`、`pathMutationAllowed=false`、`deleteAllowed=false`。

## 下一步

如果用户要真实清理该 PATH 入口，先重新生成更新准备报告和 PATH dry-run，再让用户确认新的 candidateId、候选数量和完整路径字符串。不要复用旧报告直接执行。
