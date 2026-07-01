# 备份清理 apply manifest 交接

生成时间：2026-07-01 10:55 +08:00

> Superseded：本文件是删除执行前的历史交接。2026-07-01 16:50 后的当前状态见 `docs/handoffs/2026-07-01-env-governance-cleanout-closeout-handoff.md`、`README.md` 和 `CONTEXT.md`。不要按本文件的旧 manifest、候选数量或“下一步”直接执行。

## 当前结论

本轮只完成备份清理 apply manifest 设计和收尾同步，没有执行任何删除、移动或迁移。

当前状态：

- 已提交：`e58d6e0 feat: 设计备份清理 apply manifest`
- 正式 manifest：`D:\Codex\projects\统一环境\reports\backup-retention-apply-manifest\backup-retention-apply-manifest.json`
- 中文报告：`D:\Codex\projects\统一环境\reports\backup-retention-apply-manifest\BACKUP-RETENTION-APPLY-MANIFEST.md`
- manifest id：`backup-retention-apply-20260701-104007-72e012e1`
- 选中路径：30 个
- 二次校验通过：30 个
- 阻塞路径：0 个
- 预计释放：33.2 MB
- `deleteAllowed=false`
- `executionReady=false`

## 必读文件

- 项目说明：`D:\Codex\projects\统一环境\README.md`
- 当前上下文：`D:\Codex\projects\统一环境\CONTEXT.md`
- 迁移政策：`D:\Codex\projects\统一环境\docs\env-governance\d-drive-layout-and-migration-policy.md`
- Issue 11：`D:\Codex\projects\统一环境\.scratch\unified-env\issues\11-backup-retention-apply-manifest-design.md`
- 上一阶段备份清理交接：`D:\Codex\projects\统一环境\docs\handoffs\2026-06-30-backup-retention-runtime-cleanup-handoff.md`

## 已完成

- 新增 `scripts/New-BackupRetentionApplyManifest.ps1`。
- 新增 `tests/Test-BackupRetentionApplyManifest.ps1`。
- 生成正式 apply manifest 和中文报告。
- 更新 `README.md`、`CONTEXT.md` 和 Issue 11。
- 初始化 CodeGraph 本地目录，并提交 `.codegraph\.gitignore`；数据库、WAL、log、pid 仍为本地 ignored 文件。
- 启用并验证 Serena：`scripts/New-BackupRetentionApplyManifest.ps1` 可返回函数/变量 symbol overview，diagnostics 无 warning/error。

## 安全边界

- apply manifest 不是删除授权。
- 当前脚本不包含 `Remove-Item` 或 `Move-Item` 执行路径。
- 人工审查项、保护路径、runtime shared dirs、`_autosave`、`run-evidence`、`.codex-c-backups` 不进入 manifest 可删除集合。
- 真实删除前必须重新生成 dry-run 和 manifest。
- 真实删除前必须由用户再次确认 manifest id、路径数量和预计释放体积。
- 如果 source dry-run 过期、来自未来、路径穿过 reparse point、路径落入保护/人工审查边界、或当前状态和 dry-run 指纹不一致，manifest 生成应阻塞或把路径标为 blocked。

## 验证记录

已通过：

- `tests\Test-BackupRetentionDryRun.ps1`
- `tests\Test-BackupRetentionApplyManifest.ps1`
- `tests\Test-EnvInventory.ps1`
- `tests\Test-EnvMigrationPlan.ps1`
- `tests\Test-PipCacheMigration.ps1`
- `tests\Test-EnvUpdateReadiness.ps1`
- `tests\Test-DDrivePolicyDocs.ps1`
- `tests\Test-ProjectLocalEnvReviewPack.ps1`
- `tests\Test-ProjectLocalEnvRebuildDryRunPlan.ps1`
- `tests\Test-CodexAccountSwitchDependencyUpdateDryRun.ps1`
- `git diff --check`

对抗性审查发现并已修复：

- `-UseAllDryRunCandidates` 分支必须逐项校验 D 盘边界。
- 候选路径不能是保护路径或人工审查路径的祖先。
- dry-run 时间必须从原始 JSON 严格解析，拒绝过期或未来时间。
- 测试必须覆盖伪造 C 盘 candidate、重复 `AllowPath`、过期/未来 dry-run、保护/人工审查祖先和状态漂移。

## 代码智能状态

- Serena：active and symbol-verified。
- CodeGraph：initialized but empty coverage。
  - `codegraph status D:\Codex\projects\统一环境` 显示 `Files: 0`、`Nodes: 0`、`Edges: 0`。
  - 当前项目主要是 PowerShell 脚本，CodeGraph 目前没有提供源图覆盖；后续代码导航优先用 Serena 和直接读取。

## 下一步

如果用户要进入真实删除执行，先重新生成备份 dry-run 和 apply manifest，再要求用户确认新的 manifest id、路径数量和预计释放体积。不要复用旧 manifest 直接执行。
