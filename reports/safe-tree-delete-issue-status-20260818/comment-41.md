## 状态回写（2026-08-18）

**实现关口：** `BLOCKED`
**GitHub：** 保持 OPEN。`<10%` overhead **未达**，且不靠放宽 hit-disk 假装达标。

监控、公式、报告、慢 flush 警告和 10k 夹具都在。热路径已恢复 `FileStream.Flush(true)`。#39 每文件 `pending→Flush→Delete→commit→Flush` 未改成批量 fsync。生产 Purge 未接线。

曾用 `Flush(false)` 量到 0.352%，违反「Pending entry must hit disk before OS delete」，已打回。

现役 10k（hit-disk）：`TotalFlushTimeMs=9030` / `elapsedMs=60656` = **14.887%**，`IsWithinTarget=false`，`FlushCount=20000`。删除仍成功，未失败闭锁。

`reports/safe-tree-delete-issue41-20260817/suite-meta.json`。未进默认分支。

本次只回写状态，不 `gh issue close`，不 `gh issue edit` checkbox，不 commit/push，不 Purge leftover `0ab1e1b6`，不 Archive #48 的 42 条 purged+manual-review。
