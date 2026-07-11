# Issue 14：纳入 codex_switch 安装回滚备份保留 dry-run

Status: done

> 历史说明：本 issue 中记录的 `D:\Codex\.codex\run-evidence` 路径属于当时执行快照，当前目录已退役；现行备份事实以 production schema 2 dry-run 为准。

## Parent

`.scratch/unified-env/PRD.md`

## What to build

把 `D:\Codex\apps\codex_switch\backups` 下的安装版 exe 回滚备份纳入现有“同项目同备份类型最多保留最近 5 个”的只读 dry-run 体系。

本 issue 只生成保留规则候选和人工审查项；不删除文件、不移动旧备份、不生成 apply manifest、不修改 `codex-account-switch` 构建缓存或安装目录。

## Acceptance criteria

- [x] 新增备份族 `codex-switch-installed-binary`，按 `apps/codex_switch/backups` 分组。
- [x] 目录型回滚点必须同时包含 `codex_switch.exe` 和 `WebView2Loader.dll`，否则进入人工审查。
- [x] 目录名必须能严格解析时间戳，不能用 mtime 兜底进入自动候选。
- [x] 同一备份族保留最近 5 个，超过保留数的旧目录才进入 dry-run candidates。
- [x] 旧式平铺 `codex_switch*.exe` / `WebView2Loader*.dll` 只进入人工审查，不混入自动候选。
- [x] `src-tauri\target` 等构建缓存不得混入安装版回滚备份候选。
- [x] 测试覆盖目录型回滚点、旧平铺文件、缺少 loader 的目录和构建缓存排除。

## Completion notes

- 更新脚本：`scripts/New-BackupRetentionDryRun.ps1`
- 更新测试：`tests/Test-BackupRetentionDryRun.ps1`
- 最新正式 dry-run：
  - `D:\Codex\.codex\run-evidence\env-governance\backup-retention-20260701-154928\backup-retention-dry-run.json`
  - `D:\Codex\.codex\run-evidence\env-governance\backup-retention-20260701-154928\BACKUP-RETENTION-DRY-RUN.md`
- 最新正式 dry-run 摘要：
  - 总候选：36 个，234.11 MB
  - `codex_switch` 安装回滚备份候选：6 个，200.91 MB
  - `codex_switch` 旧平铺文件人工审查项：3 个，54.78 MB
  - `deleteAllowed=false`

## Verification

- `tests/Test-BackupRetentionDryRun.ps1`

## Follow-up

如后续要清理这些安装回滚备份，必须基于最新 dry-run 重新生成 apply manifest，并由用户确认 manifest id、路径数量和预计释放体积。旧平铺文件需要先人工确认是否迁成目录型回滚点或单独处理，不能随目录型候选一键删除。

## Follow-up manifest 2026-07-01 15:52

已基于最新 dry-run 生成 apply manifest：

- manifest id：`backup-retention-apply-20260701-155200-57ae1622`
- manifest 报告：`reports/backup-retention-apply-manifest/BACKUP-RETENTION-APPLY-MANIFEST.md`
- 总候选：36 个，234.11 MB
- `codex_switch` 安装回滚备份候选：6 个，200.91 MB
- 阻塞路径：0 个
- `deleteAllowed=false`
- `executionReady=false`

## Post-apply 2026-07-01 16:12

用户已授权并执行 manifest `backup-retention-apply-20260701-155200-57ae1622`。

- 执行证据：`D:\Codex\.codex\run-evidence\env-governance\backup-retention-apply-20260701-160956\EXECUTION.md`
- 删除的 `codex_switch` 安装回滚备份：6 个，200.91 MB
- 最新 dry-run：`D:\Codex\.codex\run-evidence\env-governance\backup-retention-20260701-161022\BACKUP-RETENTION-DRY-RUN.md`
- 最新保留规则候选：0 个，0 MB
- 旧式平铺文件仍只作为人工审查项保留，未自动删除

## Manual flat-file cleanup 2026-07-01 16:27

用户已单独授权删除 3 个旧式平铺备份文件。

- 执行证据：`D:\Codex\.codex\run-evidence\env-governance\codex-switch-flat-backup-delete-20260701-162530\EXECUTION.md`
- 删除文件：3 个，54.78 MB
- 删除后剩余命中路径：0 个
- 最新 dry-run：`D:\Codex\.codex\run-evidence\env-governance\backup-retention-20260701-162612\BACKUP-RETENTION-DRY-RUN.md`
- 最新保留规则候选：0 个，0 MB
- 最新人工审查项：263 个，5166.21 MB
