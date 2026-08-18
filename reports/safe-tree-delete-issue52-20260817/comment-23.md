## 结论（先于关闭）

#23 的只读调查可以关闭。票面「69 条 schema+status 均为 null」不是对照快照事实；02:17 与之后的 #24 live 都是 **52** 条 both-null。这 52 条**全部没有 `transaction.json`**（过期计划或有意残缺），不是「事务文档在但解析器读不出来」。

本票**不再需要新代码**。把无事务过期计划扩成 Archive 会放宽合同，禁止。后续实现走已存在的 **#48**（OPEN，有意不在本收口关闭）。

现役计数以 #24 为准，不要把 02:17 的 2323 operations 写成 leftover / ProductionSmoke 之后的 live 事实。

## Acceptance criteria

| AC | 结论 | 依据 |
| --- | --- | --- |
| 每一组成因：evidence 残缺，还是解析器覆盖缺口 | **满足** | 52 条 both-null = evidence 残缺（无事务）。解析器缺口是另一批：allowlist 拒绝但**已有** v2 `purged` 事务的记录，现已能读出 status，不再落入 both-null |
| 原 34 条 capability root 组是否退役项目 + policy 撤销是否根因 | **满足（纠正票面集合）** | 票面 34 是更早基线。02:17 带该错误串的是 **40** 条：both-null **2** + `purged` **38**。明确退役路径只有雷达天梯 / okf-frontmatter；其余是仍在项目上的一次性清理根，现场写入后从工作树撤销、从未进 git。不要把已撤销 ephemeral root 写回 allowlist |
| 每组是否存在需人工处理的真实不一致 | **满足** | both-null 52 条：无数据丢失、无需要本票人工处置的真实不一致。需继续可见的 residual 不在本票 52 条里（见下） |
| 是否存在数据丢失风险 | **无** | 调查样本磁盘只有 `plan.json` 或有意残缺；`acl-capability-probe-20260801` 只有 `probe.ps1` |
| 每组处置：可归档 / 需人工 / 需代码 / 保留原状 | **满足** | both-null：**保留原状，不是 Archive 对象**。38 条已观测的 purged+manual-review：**继续 blocking，本波不 Archive**，交给 **#48**。acl probe：**保留，不删除** |
| 若需代码改动，产出后续 ticket 而非本票实施 | **满足** | 本票无新代码。后续实现票是 **#48** |
| 不得为退出视图而放宽判据 | **满足** | 未 Archive、未改判据、未改最小深度 |
| `acl-capability-probe-20260801` 保留原状 | **满足** | 缺 `plan.json` 的 1 条，不得删 |
| 只读调查，生产证据根零写入 | **满足** | #23 未调用 live wrapper。02:17 快照已在包内 |

## 三类不要混

1. **解析器覆盖缺口（已由 #48 闭合，不是本票 52 条）**
   票面把「capability root 不在 allowlist」当成未解析。方向对：其中 38 条其实是 v2 `purged`，解析器以前读不成事务。#48 让它们以 `purged` + `manual-review` 出现在视图里。它们必须继续 blocking，**不要 Archive**。

2. **无害过期 plan（本票 52 条 both-null）**
   `transactionSchemaVersion` 与 `transactionStatus` 均为 null，磁盘无 `transaction.json`。02:17 分组（调查正文，不是现役 operations 总数）：

   | 组 | 02:17 | 处置 |
   | --- | ---: | --- |
   | planned tree manifest 漂移 | 17 | 保留原状 |
   | planned namespace 不一致（无事务） | 13 | 保留原状 |
   | 同上 + policy SHA 漂移 | 18 | 保留原状 |
   | 未达最小后代深度 | 1 | 保留原状；不要把 `codex-run-evidence` 最小深度改回 1 |
   | capability root 不在 allowlist（无事务） | 2 | 保留原状 |
   | 缺 `plan.json` | 1（`acl-capability-probe-20260801`） | **保留，不删除** |

3. **真实 residual / 非 unknown（不在 both-null 里，#24 现役）**
   #24 live `blockingRecords=110` = 51 plan-only + 1 missing-plan + 42 条 #48 purged+manual-review + 10 planned-namespace + 5 条 v1 未终结 + 1 条历史 v2。另有 leftover `0ab1e1b6`（`purge-resumable`，**不在** blocking）与一条 `recoverable`。没有「不知道是什么」的账面噪声。

`complete=false` 应保持。归档合格 terminal 不蕴含 `complete=true`。

## 引用（仓库相对路径）

- 调查正文：`reports/safe-tree-delete-issue23-20260816/REPORT.md`
- 对照快照：`reports/safe-tree-delete-closeout-20260816/status-raw.utf8.json`（`capturedAtUtc=2026-08-16T02:17:18Z`）
- 现役计数：`reports/safe-tree-delete-issue24-20260816/status.summary.json`（`operationCount=2356`，`blockingRecordCount=110`，`planOnlyBothNullCount=52`）
- 现役分解：`reports/safe-tree-delete-issue24-20260816/REPORT.md`

后续实现：#48。Status 日常耗时：#49。本票不实施、不新建 ticket。
