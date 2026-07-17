# Issue 16：删除 codex_switch 旧式平铺备份文件

Status: done

> 历史说明：下列 `D:\Codex\.codex\run-evidence` 路径记录当时执行位置，相关条目可能已按保留策略清理；本 issue 与 Git 历史仅作为历史记录，不构成新的删除授权。

## Parent

`.scratch/unified-env/PRD.md`

## What to execute

基于用户单独授权，删除 `D:\Codex\apps\codex_switch\backups` 下 3 个旧式平铺备份文件。

本 issue 只覆盖用户确认的 3 个文件；不删除目录型安装回滚备份、当前 `codex_switch` 运行文件、构建缓存、账号状态、插件缓存、run-evidence 或其他人工审查项。

## Authorization

用户已确认：

```text
全部删除这三个
```

## Deleted files

- `D:\Codex\apps\codex_switch\backups\codex_switch-before-appserver-login-20260625-161207.exe`
- `D:\Codex\apps\codex_switch\backups\codex_switch-before-local-patch-20260625-154636.exe`
- `D:\Codex\apps\codex_switch\backups\WebView2Loader-before-appserver-login-20260625-161207.dll`

## Completion notes

- 执行证据：`D:\Codex\.codex\run-evidence\env-governance\codex-switch-flat-backup-delete-20260701-162530\EXECUTION.md`
- 删除前校验：`D:\Codex\.codex\run-evidence\env-governance\codex-switch-flat-backup-delete-20260701-162530\preflight-items.json`
- 删除结果：`D:\Codex\.codex\run-evidence\env-governance\codex-switch-flat-backup-delete-20260701-162530\deleted-items.json`
- 删除文件：3 个
- 释放体积估算：54.78 MB
- 删除后剩余命中路径：0 个

## Post-delete verification

- 最新 dry-run：`D:\Codex\.codex\run-evidence\env-governance\backup-retention-20260701-162612\BACKUP-RETENTION-DRY-RUN.md`
- 当时的 schema 1 apply manifest 已移除；当前没有可发布的 schema 2 apply manifest。
- 最新保留规则候选：0 个，0 MB
- 最新人工审查项：263 个，5166.21 MB
- 最新 apply manifest 选中路径：0 个，0 MB

## Verification

- 已确认 3 个精确路径删除后不存在。
- 已重新生成 backup retention dry-run。
- 已重新生成 backup retention apply manifest。
