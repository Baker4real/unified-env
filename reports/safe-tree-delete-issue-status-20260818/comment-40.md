## 状态回写（2026-08-18）

**实现关口：** `DONE_WITH_CONCERNS`
**GitHub：** 保持 OPEN。

夹具 `File.Delete` 基准（不是生产 Purge）：10k×1KB DOP4=13255ms / DOP1=59439ms = **4.48x**（效率峰值）；DOP2=2.17x。`FromDetection` optimize 仍为 4。这些数字不得加进 #42 生产倍率。

#21 回归曾覆盖 `reports/safe-tree-delete-issue40-20260817/raw/`。之后 ParallelismBenchmark 改为写入 `reports/safe-tree-delete-parallelism-benchmark/`；对 frozen #40 raw 做 SHA 守卫。Phase3 不再钉历史 `wallClockMs==13255`。

未进默认分支。生产 Purge 未接 coordinator。

本次只回写状态，不 `gh issue close`，不 `gh issue edit` checkbox，不 commit/push，不 Purge leftover `0ab1e1b6`，不 Archive #48 的 42 条 purged+manual-review。
