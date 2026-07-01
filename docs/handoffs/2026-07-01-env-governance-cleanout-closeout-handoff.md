# 统一环境治理清理收尾交接

生成时间：2026-07-01 16:55 +08:00

## 当前结论

本轮已经完成 PATH 失效入口清理、备份保留 apply、`codex_switch` 旧式平铺备份删除，以及三类人工审查项删除。旧 handoff 中“尚未删除”“下一步需要执行”的说法只作为历史记录保留，不能作为当前状态使用。

当前最新事实以本文件、`README.md`、`CONTEXT.md`、各 issue 15-17 和最新 dry-run 为准。

## 已执行清理

- User scope PATH：已移除失效入口 `D:\hermes-agent\.venv\Scripts`。
- 备份保留 apply：已删除 manifest `backup-retention-apply-20260701-155200-57ae1622` 中 36 个已验证路径，估算释放 234.11 MB。
- `codex_switch` 旧式平铺备份：已删除 3 个文件，估算释放 54.78 MB。
- 三类人工审查项：已删除 5 个路径，估算释放 1215.85 MB。

## 最新证据

- PATH 清理执行证据：`D:\Codex\.codex\run-evidence\env-governance\path-cleanup-20260701-151054\EXECUTION.md`
- 备份保留 apply 执行证据：`D:\Codex\.codex\run-evidence\env-governance\backup-retention-apply-20260701-160956\EXECUTION.md`
- `codex_switch` 旧式平铺备份删除证据：`D:\Codex\.codex\run-evidence\env-governance\codex-switch-flat-backup-delete-20260701-162530\EXECUTION.md`
- 三类人工审查项删除证据：`D:\Codex\.codex\run-evidence\env-governance\manual-review-cleanup-20260701-164124\EXECUTION.md`
- 最新备份保留 dry-run：`D:\Codex\.codex\run-evidence\env-governance\backup-retention-20260701-164920\BACKUP-RETENTION-DRY-RUN.md`
- 最新 apply manifest 报告：`D:\Codex\projects\统一环境\reports\backup-retention-apply-manifest\BACKUP-RETENTION-APPLY-MANIFEST.md`

## 最新 dry-run 摘要

- 保留规则候选：0 个，0 MB
- apply manifest 选中路径：0 个，0 MB
- 人工审查项：258 个，3950.71 MB
- `deleteAllowed=false`
- `executionReady=false`

## 仍需保护的边界

- 不自动删除 `auth.json`、`profile.json`、`install_state.json`、`quota_cache.json`。
- 不自动删除当前 `skills`、当前 `plugins/cache`、runtime shared-cache、`run-evidence` 或其他人工审查项。
- 后续如继续清理剩余 3950.71 MB，必须重新生成 dry-run，按类别重新梳理并取得显式授权。
- 旧 handoff 里提到的 `.codex-c-backups` “不要删除”是删除前保守边界；本轮已经在用户明确授权后删除，当前不应把它当作仍存在路径。

## 验证记录

本轮最后一次清理后已通过：

- `git diff --check`
- `tests\Test-BackupRetentionDryRun.ps1`
- `tests\Test-BackupRetentionApplyManifest.ps1`

项目当前提交到 `main`，对应清理提交是：

- `2aea56c docs: record manual review cleanup execution`

## 下一步建议

如果继续治理剩余人工审查项，优先只读梳理：

- `D:\Codex\.codex\run-evidence`：当前最大项，属于运行证据，默认不删。
- `runtime/shared-cache`：插件和缓存共享运行态，默认不删。
- 小体积旧备份根：可单独梳理，但不能和运行证据或 runtime/cache 混成一个授权。
