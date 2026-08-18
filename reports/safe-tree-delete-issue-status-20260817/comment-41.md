## 状态回写（2026-08-17）

**实现关口：** `DONE_WITH_CONCERNS`
**GitHub：** 保持 OPEN。

夹具 10k journal flush：TotalFlushTimeMs 6144 / elapsed 32927ms = overhead **18.659%**，`IsWithinTarget=false`（目标 <10%）。公式是线程求和，不是墙钟伪装。

生产 HostSafety journal 是串行 create-only，没有这条 flush 占比合同。

`reports/safe-tree-delete-issue41-20260817/scale-10000.json`。未进默认分支。

本次只回写状态，不 `gh issue close`，不 commit/push，不 Purge leftover `0ab1e1b6`。
