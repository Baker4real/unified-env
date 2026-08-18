## 状态回写（2026-08-18）

**实现关口：** `DONE_WITH_CONCERNS`
**GitHub：** 保持 OPEN。数字 AC 未满足的子票仍 OPEN。

库、Plan 采集、Apply/Purge 会话哈希复用、uncertain、批量验证、夹具 coordinator / journal 监控、操作者指南都已在工作树落地。生产 Plan→Apply→Purge **未达**票面 4–6x：

- #36：10k×160KiB，**1.02x**，`metTarget=false`
- #42：10k×4KB，**0.962x**，`metTarget=false`

生产 Purge **未接** `ParallelPurgeCoordinator`，仍走 HostSafety 串行删除。#40 夹具 DOP4=4.48x 是 `File.Delete` 墙钟，不是生产加速。

子票关口：#32 / #41 **BLOCKED**（数字不可达且不放宽安全合同）；#33 / #35 / #39 / #40 / #43 功能或文档关口已齐但未关 GitHub；#36 / #37 / #42 倍率未达。Status / BatchPurge 属 #49，不在本票。

实现仍在工作树，未把性能 DAG 整包推进默认分支。

本次只回写状态，不 `gh issue close`，不 `gh issue edit` checkbox，不 commit/push，不 Purge leftover `0ab1e1b6`，不 Archive #48 的 42 条 purged+manual-review。
