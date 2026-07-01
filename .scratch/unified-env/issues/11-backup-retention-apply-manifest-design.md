# Issue 11：设计备份清理 apply manifest

Status: done

## Parent

`.scratch/unified-env/PRD.md`

## What to build

基于最新备份保留 dry-run JSON，生成删除前 `apply manifest` 设计。该切片只负责把候选路径固化成可审查、可二次校验、可最终授权的 manifest，不执行删除、不移动目录、不创建 junction、不把人工审查项混入可删除集合。

目标是把“apply 前要确认什么”变成机器可读 JSON 和中文报告，而不是把真实删除逻辑直接藏进 dry-run 脚本。

## Acceptance criteria

- [x] 读取并遵守 `docs/env-governance/d-drive-layout-and-migration-policy.md`、`docs/handoffs/2026-06-30-backup-retention-runtime-cleanup-handoff.md` 和 Issue 09 的 completion notes。
- [x] 新增 apply manifest 脚本，只读取最新 dry-run JSON 并生成 manifest，不包含 `Remove-Item` / `Move-Item`。
- [x] manifest 必须明确 `applyManifestOnly=true`、`readOnly=true`、`deleteAllowed=false`、`executionReady=false`。
- [x] 生成 manifest 时必须显式选择路径：要么 `-UseAllDryRunCandidates`，要么传入一个或多个 `-AllowPath`；缺省不得自动选择。
- [x] `AllowPath` 必须逐项存在于 dry-run `candidates` 中；人工审查项、保护路径、runtime/cache/sqlite、`_autosave`、`run-evidence`、`.codex-c-backups` 不得进入 manifest。
- [x] 每个候选路径必须二次校验当前状态：D 盘边界、reparse point、存在性、bytes、files、dirs、SKILL.md 数、newestUtc、oldestUtc。
- [x] 当前状态与 dry-run 快照不一致时，路径必须进入 manifest 的 blocked item，而不是继续标为可最终授权。
- [x] manifest 必须包含稳定 candidate id、manifest id、源 dry-run 路径、源 dry-run 时间、候选数量、预计体积、阻塞数量和最终授权短语。
- [x] Markdown 报告必须用中文说明：这是 apply 设计，不是删除授权；真实删除前还要再次确认 manifest id、路径数量和预计释放体积。
- [x] 有测试覆盖：阻止 C 盘输出、阻止缺少选择模式、阻止人工审查路径、证明脚本不含删除/移动命令、证明状态漂移会阻塞。

## Blocked by

- `.scratch/unified-env/issues/09-backup-retention-dry-run.md`
- `docs/handoffs/2026-06-30-backup-retention-runtime-cleanup-handoff.md`
- `docs/env-governance/d-drive-layout-and-migration-policy.md`

## Comments

本 issue 不包含真实删除授权。后续如果要执行删除，必须另建执行 issue 或由用户在当前上下文中逐字确认 manifest id、路径数量和预计释放体积。

## Completion notes

- 新增脚本：`scripts/New-BackupRetentionApplyManifest.ps1`。
- 新增测试：`tests/Test-BackupRetentionApplyManifest.ps1`。
- 正式 manifest 设计产物：
  - `reports/backup-retention-apply-manifest/backup-retention-apply-manifest.json`
  - `reports/backup-retention-apply-manifest/BACKUP-RETENTION-APPLY-MANIFEST.md`
- 正式 manifest 摘要：
  - manifest id：`backup-retention-apply-20260701-104007-72e012e1`
  - source dry-run：`D:\Codex\.codex\run-evidence\env-governance\backup-retention-20260701-080621\backup-retention-dry-run.json`
  - 选中路径：30 个，33.2 MB
  - 通过二次校验：30 个，33.2 MB
  - 阻塞路径：0 个
  - `deleteAllowed=false`
  - `executionReady=false`
- 本 issue 仍不包含真实删除。下一阶段如要执行，必须再次重新生成 dry-run 和 manifest，并要求用户确认 manifest id、路径数量和预计释放体积。
