# Issue 09：生成备份膨胀治理 dry-run 脚本与最新报告

Status: done

## Parent

`.scratch/unified-env/PRD.md`

## What to build

基于最新本机状态生成备份膨胀治理 dry-run 脚本和报告。该切片只负责盘点、分类、输出候选清单和安全边界，不删除、不移动、不迁移任何真实目录。

目标是把“同项目同备份类型按时间倒序最多保留 5 个”落实为可审查的候选清单，而不是把清理逻辑藏进登录、refresh、autosave 或账号切换等核心生命周期函数。

## Acceptance criteria

- [x] 读取并遵守 `docs/env-governance/d-drive-layout-and-migration-policy.md` 和 `docs/handoffs/2026-06-30-backup-retention-runtime-cleanup-handoff.md`。
- [x] 新增备份膨胀治理脚本，只执行只读扫描和 dry-run 计算，不删除、不移动、不重命名任何目录。
- [x] 重新生成最新 dry-run JSON 和中文 Markdown 报告，不复用旧 handoff 里的候选清单作为当前事实或执行依据。
- [x] 明确 `dryRun=true`、`readOnly=true`、`deleteAllowed=false`，且脚本不包含删除或移动逻辑。
- [x] 保护当前 `skills`、当前 `plugins/cache`、`account_backup` 根、`auth.json`、`profile.json`、`install_state.json`、`quota_cache.json`。
- [x] 运行态 `plugins/cache/sqlite` 共享行为只能作为保护边界记录，不能被改成自动 prune。
- [x] `plugins`、`.tmp`、`_autosave`、`run-evidence`、`.codex-c-backups` 默认进入人工审查，不得进入自动保留删除候选。
- [x] 候选路径必须位于 D 盘允许根，且不能穿过 junction、symlink 或 reparse point；命中时进入人工审查。
- [x] 按组保留规则必须有可审计分组键：项目根、备份类型、严格解析出的目录名时间戳；不能用 mtime 或模糊正则兜底。
- [x] 按组保留规则必须保留最新 5 个，其余只列为候选，并标出组名、时间戳来源、风险、理由和阻塞条件。
- [x] 高风险证据目录、历史账号备份、`.codex-c` 备份和 auth 自动快照必须单独确认，不得混入低风险一键清理。
- [x] 输出证据位于 `D:\Codex\.codex\run-evidence\env-governance\` 或本项目 `reports\`，不得写入 C 盘。
- [x] 有测试覆盖：阻止 C 盘输出、阻止非授权 D 盘输出、保护路径存在、候选项默认不可直接 apply、runtime/证据/历史迁移备份不得进入候选。

## Blocked by

- `docs/handoffs/2026-06-30-backup-retention-runtime-cleanup-handoff.md`
- `docs/env-governance/d-drive-layout-and-migration-policy.md`

## Comments

本 issue 不包含真实清理授权。后续若要执行删除，必须新建 apply issue 或让用户在当前上下文中明确确认具体路径和类别；笼统的“继续”不等于删除授权。

上一轮 handoff 中关于“修改 runtime 复制策略避免复制插件缓存”的建议已经被推翻。后续工作不能再把 `plugins`、`cache`、`sqlite` 从 runtime 共享列表移除，也不能把 `plugins` 或 `.tmp` 整体加入自动删除范围。

旧 dry-run 只能作为历史线索，不能作为 apply manifest。Issue 09 的目标是先证明哪些才是真备份、哪些必须保护或人工审查。

## Completion notes

- 新增只读脚本：`scripts/New-BackupRetentionDryRun.ps1`。
- 新增测试：`tests/Test-BackupRetentionDryRun.ps1`。
- 最新正式 dry-run 证据：
  - `D:\Codex\.codex\run-evidence\env-governance\backup-retention-20260701-080621\backup-retention-dry-run.json`
  - `D:\Codex\.codex\run-evidence\env-governance\backup-retention-20260701-080621\BACKUP-RETENTION-DRY-RUN.md`
- 最新 dry-run 摘要：保留规则候选 30 个，约 33.2 MB；人工审查项 263 个，约 5079.75 MB；`deleteAllowed=false`。
- 候选中 runtime、`_autosave`、`run-evidence`、`.codex\backups` 计数均为 0；这些路径默认进入保护或人工审查。
- 验证通过：`tests/Test-BackupRetentionDryRun.ps1`。
