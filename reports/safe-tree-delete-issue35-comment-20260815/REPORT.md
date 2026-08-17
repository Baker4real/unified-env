# #35 2026-08-15 评论对齐：删除路径消费 DeletionAllowed

对照 GitHub #35 最新评论（2026-08-15 代码对齐审查）：检测对象已定义但未接入删除路径。本轮只把 `DetectFileSystem` / `DeletionAllowed` 接到 Plan / Apply / Purge 共同失败闭锁，并补入口级回归。

## 接入点（当前工作树行号）

- 共同函数：`Assert-CodexSafeTreeDeleteDeletionAllowed`（`scripts/lib/CodexSafeTreeDelete.ps1:891`）
- Plan：`New-CodexSafeTreeDeletePlan` resolve target 之后（`:930`），写 evidence / tree snapshot 之前
- Apply：`Invoke-CodexSafeTreeDeleteQuarantine` 读到 target 之后（`:2831`），写 transaction / rename 之前
- Purge：`Invoke-CodexSafeTreeDeletePurge` 读到 target 之后（`:4366`），mutex / delete / 缺 quarantine 恢复写之前

生产路径调用真实 `FileSystemDetector.DetectFileSystem`。测试可通过 `FileSystemCapabilitiesForTest` 注入预构造能力对象；生产 CLI 未增加 override。

Purge 探测路径：Apply 后原 target 已不存在，`DetectFileSystem` 对缺路径会得到 `DeletionAllowed=false`。因此生产 Purge 对现存 quarantine 探测，quarantine 也不在时回退 capability root。这不是把网络卷一律禁止。

## 验证

| 测试 | 退出码 |
| --- | --- |
| `tests/Test-CodexSafeTreeDeleteFileSystem.ps1` | 0（先红：共同函数不存在；后绿） |
| `tests/Test-CodexSafeTreeDeleteIdentityV2.ps1` | 0 |
| `tests/Test-CodexSafeTreeDeletePlanIdentityV2.ps1` | 0 |
| `git diff --check`（改动文件） | 0 |

入口回归覆盖：FAT32 / exFAT / 无 FILE_ID_INFO / 网络且无 FileId 的预构造 `DeletionAllowed=false` 在 fixture Plan/Apply/Purge 失败闭锁且零写入；网络+FileId 与本机 NTFS 仍允许 Plan。本机无真实 FAT32/exFAT/网络卷。

未跑 ProductionSmoke。未关票。未 commit / push / comment。
