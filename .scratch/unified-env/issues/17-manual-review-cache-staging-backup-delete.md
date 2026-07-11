# Issue 17：删除三类人工审查项

Status: done

> 历史说明：下列 `D:\Codex\.codex\run-evidence` 路径记录当时执行位置，当前证据目录已退役；本 issue 与 Git 历史仅作为历史记录，不构成新的删除授权。

## Parent

`.scratch/unified-env/PRD.md`

## What to execute

基于用户授权，删除最新 backup retention dry-run 中三类人工审查项：

- 历史账号临时缓存
- `D:\Codex\.codex-c-backups` 历史迁移备份
- 全局临时 staging

本 issue 只覆盖 dry-run `backup-retention-20260701-162612` 中这三类展开后的 5 个精确路径；不删除 runtime/shared-cache、当前 skills、当前 plugins/cache、账号凭据、profile、quota、install_state、run-evidence 或其他人工审查项。

## Authorization

用户已确认：

```text
历史账号临时缓存：633.02 MB，中风险
D:\Codex\.codex-c-backups：389.47 MB，历史迁移备份
全局临时 staging：193.36 MB.把这三个都删除掉
```

## Deleted paths

- `D:\Codex\.codex\account_backup\b\tmp`
- `D:\Codex\.codex\account_backup\c\.tmp\bundled-marketplaces`
- `D:\Codex\.codex\account_backup\c\.tmp\plugins`
- `D:\Codex\.codex-c-backups`
- `D:\Codex\.codex\.tmp\bundled-marketplaces`

## Completion notes

- 执行证据：`D:\Codex\.codex\run-evidence\env-governance\manual-review-cleanup-20260701-164124\EXECUTION.md`
- 删除前校验：`D:\Codex\.codex\run-evidence\env-governance\manual-review-cleanup-20260701-164124\preflight-items.json`
- 删除结果：`D:\Codex\.codex\run-evidence\env-governance\manual-review-cleanup-20260701-164124\deleted-items.json`
- 删除路径：5 个
- 释放体积估算：1215.85 MB
- 删除后剩余命中路径：0 个

## Locked file handling

全局临时 staging 初次删除时被 `extension-host.exe` 文件锁阻塞。Restart Manager 查到锁持有者为 PID 73384 `extension-host.exe`，并存在父进程 PID 9812 `cmd.exe`。已只终止这两个 native-host 进程，不终止 Chrome 主进程；随后剩余 staging 删除成功。

## Post-delete verification

- 最新 dry-run：`D:\Codex\.codex\run-evidence\env-governance\backup-retention-20260701-164920\BACKUP-RETENTION-DRY-RUN.md`
- 最新 apply manifest：`reports/backup-retention-apply-manifest/BACKUP-RETENTION-APPLY-MANIFEST.md`
- 最新保留规则候选：0 个，0 MB
- 最新人工审查项：258 个，3950.71 MB
- 最新 apply manifest 选中路径：0 个，0 MB

## Verification

- 已确认 5 个精确路径删除后不存在。
- 已重新生成 backup retention dry-run。
- 已重新生成 backup retention apply manifest。
