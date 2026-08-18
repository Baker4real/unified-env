## 状态回写（2026-08-17）

**实现关口：** DONE（2026-08-16 已回写过观测合同）。
**GitHub：** 保持 OPEN。本票有意不在 #45 关票序列里关闭。

plan 被当前 policy 拒绝后，Status 仍只读观测历史事务。生产里 42 条 `purged` + `lifecycle=manual-review` **是观测成功**，必须继续计入 blocking。不要为本票去清 blocking 或 Archive 这 42 条。

现役 #24：blocking=110，其中这 42 条仍在。未改 Status 实现。

本次只回写状态，不 `gh issue close`，不 commit/push，不 Purge leftover `0ab1e1b6`。
