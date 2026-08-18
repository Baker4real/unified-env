## 状态回写（2026-08-18）

**实现关口：** waiver（维护者已接受）
**GitHub：** 保持 OPEN。关票仍要另授 close。

Detect / `DeletionAllowed` 已接。FAT32 / 网络实卷 e2e 未提权验证。现役：FAT32/exFAT 强制无 `FILE_ID_INFO`，`DeletionAllowed=false`，新 Plan 失败关闭。

#21 fixture 全量里 `Test-CodexSafeTreeDeleteFileSystem.ps1` 仍因 diskpart Win32 740 红。这是本票 waiver，不是 DetectFileSystem 回归，不改生产探测去「修绿」。

本次只回写状态，不 `gh issue close`，不 `gh issue edit` checkbox，不 commit/push，不 Purge leftover `0ab1e1b6`，不 Archive #48 的 42 条 purged+manual-review。
