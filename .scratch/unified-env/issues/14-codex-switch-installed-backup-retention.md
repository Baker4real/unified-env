# Issue 14：纳入 codex_switch 安装回滚备份保留 dry-run

Status: done

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
  - `D:\Codex\.codex\run-evidence\env-governance\backup-retention-20260701-152420\backup-retention-dry-run.json`
  - `D:\Codex\.codex\run-evidence\env-governance\backup-retention-20260701-152420\BACKUP-RETENTION-DRY-RUN.md`
- 最新正式 dry-run 摘要：
  - 总候选：36 个，234.11 MB
  - `codex_switch` 安装回滚备份候选：6 个，200.91 MB
  - `codex_switch` 旧平铺文件人工审查项：3 个，54.78 MB
  - `deleteAllowed=false`

## Verification

- `tests/Test-BackupRetentionDryRun.ps1`

## Follow-up

如后续要清理这些安装回滚备份，必须基于最新 dry-run 重新生成 apply manifest，并由用户确认 manifest id、路径数量和预计释放体积。旧平铺文件需要先人工确认是否迁成目录型回滚点或单独处理，不能随目录型候选一键删除。
