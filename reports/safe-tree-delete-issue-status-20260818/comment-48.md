## 状态回写（2026-08-18）

**实现关口：** DONE（观测合同仍成立）。
**GitHub：** 保持 OPEN。本票有意不在 #45 关票序列里关闭。

plan 被当前 policy 拒绝后，Status 仍只读观测历史事务。生产里 **42** 条 `purged` + `lifecycle=manual-review` 是观测成功，必须继续计入 blocking。

#49 三次冷启动仍报告 `purgedManualReviewCount=42`。不要 Archive 这 42 条来换 Status 墙钟。`tests/Test-CodexSafeTreeDeleteStatus.ps1` slices=22。相关 Status 优化在工作树，未进默认分支。

本次只回写状态，不 `gh issue close`，不 `gh issue edit` checkbox，不 commit/push，不 Purge leftover `0ab1e1b6`，不 Archive #48 的 42 条 purged+manual-review。
