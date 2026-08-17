## 结论回写（2026-08-16）

结论：**实现与已能做的验收仍满足 2026-08-15 维护者 waiver 后的关闭条件；保持 OPEN，本次不 close。**

2026-08-15 最新评论已写明：真实 FAT32/exFAT/网络卷上的 Plan/Apply/Purge 端到端拒绝 **不再是** 关闭本票的必要条件。关闭只需承认：检测对象、推荐矩阵、删除路径消费 `DeletionAllowed`、以及现有测试（含一次提权 FAT32 上的 Detect / 共同闭锁）已经足够。

### 复验

- `Assert-CodexSafeTreeDeleteDeletionAllowed` 仍在 `scripts/lib/CodexSafeTreeDelete.ps1:892-910`；调用点：Plan `:931`，Apply `:2960`，Purge `:4518`。
- 2026-08-16 未提升会话跑 `tests/Test-CodexSafeTreeDeleteFileSystem.ps1` **exit 1**：`diskpart.exe` Win32 740（需要提升），C–F 全是 NTFS，一次性 FAT32 VHD 建不出来。这落在已豁免的实卷 e2e 上，不是 `DeletionAllowed` 未接入。
- 提权 FAT32 VHD 绿灯仍以 2026-08-15 快照为准：`reports/safe-tree-delete-issue35-livefs-20260815/`。本波次未再申请提权造卷。

### 本票不再做

- 不为关票给 FileSystem 测试加 skip。
- 不再打真实 FAT32 字母盘上的 fixture Plan（仍会先被 D 盘路径治理或 reparse 挡住）。
- 未测网络卷。

本次未 close、未改热路径、未 commit/push。
