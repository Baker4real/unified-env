## 状态回写（2026-08-18）

**实现关口：** `DONE_WITH_CONCERNS`
**GitHub：** 保持 OPEN。关票仍要另授 close。

票面文档 AC 已落到性能 spec「操作者指南」：三阶段落地、FILE_ID_INFO、哈希复用、并行仅夹具、两层实测表。生产表写已测 **1.02x / 0.962x**，写明未达票面 4x/6x。夹具 4.48x 单独成表。

#41 现役 hit-disk overhead 是 **14.887%**（`Flush(true)` 打回后）。若指南里仍出现较早的 18.659% / 0.352%，以 #41 `suite-meta.json` 为准，不要把 `<10%` 写成已上线。

`reports/safe-tree-delete-issue43-20260817/CLOSEABLE.md`。文档改动仍在工作树。

本次只回写状态，不 `gh issue close`，不 `gh issue edit` checkbox，不 commit/push，不 Purge leftover `0ab1e1b6`，不 Archive #48 的 42 条 purged+manual-review。
