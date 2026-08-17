## 结论回写（2026-08-15）：本票停在当前现状

结论：**实现与已能做的验收到此为止。** 因本机与提权/路径治理限制，不再继续补实卷上的 Plan/Apply/Purge 入口拒绝。此前评论把「真实 FAT32/exFAT/网络卷端到端入口拒绝」当作关闭门槛的部分，**即日起不再作为关闭本 issue 的必要条件**。

本次只回写结论，不执行 `gh issue close`。

### 已落地

- `FileSystemCapabilities` / `DetectFileSystem` / `TestFileIdSupport` 在 `scripts/lib/CodexSafeTreeDeleteFileIdentity.cs`。
- 共同闭锁 `Assert-CodexSafeTreeDeleteDeletionAllowed` 已接入 Plan / Apply / Purge；`DeletionAllowed=false` 时失败闭锁。生产 CLI 不能注入 ForTest。
- FAT32/exFAT：`SupportsFileId128=false`，关哈希复用与并行，`DeletionAllowed=false`。网络 + FileId 仍允许删除，没有一律禁网。
- 单元 / 预构造 capabilities 的 Plan/Apply/Purge 拒绝、本机 NTFS 允许路径：`tests/Test-CodexSafeTreeDeleteFileSystem.ps1` 覆盖。
- 2026-08-15T13:10:11Z 提权会话（`elevatedProcessIsAdministrator=true`）用一次性 FAT32 VHD 跑通同一测试，**exit 0**，7 slices。证据：`reports/safe-tree-delete-issue35-livefs-20260815/elevated-filesystem.meta.json`。
  - 实卷 `DetectFileSystem`：`FileSystemType=FAT32`，`DeletionAllowed=false`，`TestFileIdSupport=false`。
  - 对实卷路径、不注入 ForTest 的 `Assert-CodexSafeTreeDeleteDeletionAllowed` 失败闭锁。
  - VHD 已卸载删除；本机 `C:\`–`F:\` 仍全是 NTFS。

### 做到这里停，不再做

- fixture Plan 在真实 FAT32 盘符上先被 **D 盘路径治理**挡住（policy 落在 `G:\`，`livePlanLayer=d-path-governance`），没有打到「因 `DeletionAllowed` 拒绝」那一层。
- 把同一卷挂到 D 盘目录时，policy 快照 `reparse-blocked`（文件夹挂载是 reparse）。
- 本机无网络卷，网络场景未测。
- 未再改热路径去迁就非 D 盘 FAT32，也未再申请提权造卷。

这些限制下继续打「Plan/Apply/Purge 入口因文件系统拒绝」成本高、且会碰到治理合同，**按维护者决定不再执行**。

### 对先前关闭条件的更正

下列内容曾被写成关闭前动作或安全门槛，现明确 **不再作为关闭本票的必要条件**：

- 真实 FAT32/exFAT/网络卷上的 fixture/生产 Plan、Apply、Purge 端到端拒绝
- 用实卷证明删除入口（而不只是共同闭锁函数）因缺少 `FILE_ID_INFO` 而停住
- 本机没有的网络卷集成

关闭本票只需承认：检测对象、推荐矩阵、删除路径消费 `DeletionAllowed`、以及现有测试（含一次提权 FAT32 上的 Detect / 共同闭锁）已经足够。剩余实卷入口层是可选后续，不是本票 blocker。
