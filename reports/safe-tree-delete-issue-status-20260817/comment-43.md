## 状态回写（2026-08-17）

**实现关口：** `DONE_WITH_CONCERNS`
**GitHub：** 保持 OPEN。

票面 16 条 AC 已落到现役性能 spec「操作者指南」：三阶段落地、FILE_ID_INFO、哈希复用、并行仅夹具、两层实测表、故障排查、必须重 Plan、API 现役契约。未另造第三份用户指南。

生产表写已测 **1.02x / 0.962x**，并写明未达票面 4x/6x。夹具 4.48x 单独成表。同文件后部设计段仍有 4–6x 目标语，已标明不是已测。

`reports/safe-tree-delete-issue43-20260817/CLOSEABLE.md`。未进默认分支。

本次只回写状态，不 `gh issue close`，不 commit/push，不 Purge leftover `0ab1e1b6`。
