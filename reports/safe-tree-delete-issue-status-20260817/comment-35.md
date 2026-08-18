## 状态回写（2026-08-17）

**实现关口：** waiver（维护者已接受）
**GitHub：** 保持 OPEN。关票仍要另授 close。

FAT32 / 网络实卷 e2e 未提权验证。现役探测：FAT32/exFAT 强制无 `FILE_ID_INFO`，`DeletionAllowed=false`，新 Plan 失败关闭。`RecommendParallel=false` 只约束夹具 coordinator；生产 Purge 本来就是串行。

FileSystem 测试未提权会因 diskpart 740 红，这是已知 waiver，不是本波新回归。

本次只回写状态，不 `gh issue close`，不 commit/push，不 Purge leftover `0ab1e1b6`。
