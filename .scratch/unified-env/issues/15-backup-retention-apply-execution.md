# Issue 15：执行备份保留 apply 删除

Status: done

## Parent

`.scratch/unified-env/PRD.md`

## What to execute

基于用户逐字授权，执行 manifest `backup-retention-apply-20260701-155200-57ae1622` 中 36 个已验证备份目录的删除。

本 issue 只覆盖 manifest 中通过二次校验且经最终授权的路径；不删除人工审查项、保护路径、当前运行时目录、构建缓存或旧式平铺 `codex_switch*.exe` / `WebView2Loader*.dll` 文件。

## Authorization

用户已确认：

```text
我确认删除 manifest backup-retention-apply-20260701-155200-57ae1622 中的 36 个已验证路径，预计释放 234.11 MB
```

## Completion notes

- 执行证据：`D:\Codex\.codex\run-evidence\env-governance\backup-retention-apply-20260701-160956\EXECUTION.md`
- source manifest 备份：`D:\Codex\.codex\run-evidence\env-governance\backup-retention-apply-20260701-160956\source-manifest.json`
- 删除前校验清单：`D:\Codex\.codex\run-evidence\env-governance\backup-retention-apply-20260701-160956\preflight-items.json`
- 删除结果：`D:\Codex\.codex\run-evidence\env-governance\backup-retention-apply-20260701-160956\deleted-items.json`
- 删除路径：36 个
- 释放体积估算：234.11 MB
- 删除后剩余路径数：0

## Post-apply verification

- 最新 dry-run：`D:\Codex\.codex\run-evidence\env-governance\backup-retention-20260701-161022\BACKUP-RETENTION-DRY-RUN.md`
- 最新 apply manifest：`reports/backup-retention-apply-manifest/BACKUP-RETENTION-APPLY-MANIFEST.md`
- 最新保留规则候选：0 个，0 MB
- 最新 apply manifest 选中路径：0 个，0 MB
- 阻塞路径：0 个
- `deleteAllowed=false`
- `executionReady=false`

## Verification

- `tests/Test-BackupRetentionDryRun.ps1`
- `tests/Test-BackupRetentionApplyManifest.ps1`
- 已确认 `D:\Codex\projects\codex-gsd-codex-c-skill` 工作区未被改脏。
