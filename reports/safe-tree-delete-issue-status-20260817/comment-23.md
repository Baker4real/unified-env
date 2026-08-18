## 状态回写（2026-08-17）

**实现关口：** DONE（只读调查，无新代码）。
**GitHub：** 保持 OPEN。关闭走 #52。

票面「69 条 schema+status 均为 null」不是对照快照事实。02:17 与之后的 #24 live 都是 **52** 条 both-null，且全部没有 `transaction.json`（过期计划或有意残缺），不是解析器读不出来。

这 52 条保留原状，不是 Archive 对象。解析器缺口那批（allowlist 拒绝但已有 v2 `purged` 事务）已由 #48 观测出来，必须继续 blocking，不要为本票 Archive。`acl-capability-probe-20260801` 保留，不删除。

现役计数以 #24 为准（2356 / 110）。

本次只回写状态，不 `gh issue close`，不 commit/push，不 Purge leftover `0ab1e1b6`。
