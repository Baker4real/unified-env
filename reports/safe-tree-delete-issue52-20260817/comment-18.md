## 结论（先于关闭）

父 spec #18 可以在 **#20–#24 全部 CLOSED 且本评论可见** 之后关闭。

控制面收口完成的是：合格 terminal 已归档并退出 blocking；wrapper 传递非零退出码；未解析记录已归因；`complete` 恢复判定价值。**没有**把 Status 做到日常秒级，也**没有**把 `migrationReadiness.ready` 翻成 true。这两件事分别由有意开放的 **#49** 与仍为 false 的合理终态解释。

**#48 / #49 保持 OPEN。** 它们是范围外 successor，不是本父票漏关的子票。

## #20–#24

| 票 | 结论 | 现役依据 |
| --- | --- | --- |
| #19 | 已 CLOSED | 归档前基线 `reports/safe-tree-delete-status-baseline-20260810.json` |
| #20 | 只主张转发 `$LASTEXITCODE`；不吞并 #47/#55 | `reports/safe-tree-delete-issue55-20260816/identity.json` |
| #21 | 端到端非零断言已并入 ProductionSmoke | **唯一非零主证据** `reports/safe-tree-delete-issue55-20260816/leaf-delete-failed.json` `exitCode=1` |
| #22 | 合格 terminal 已归档；现役 blocking=110 | #24 live，不是 02:17 |
| #23 | 52 条 both-null 是过期/残缺计划；解析器缺口交给 #48 | `reports/safe-tree-delete-issue23-20260816/REPORT.md` |
| #24 | `complete=false` 合理；Status 仍约 8.2 分钟 → #49 | `reports/safe-tree-delete-issue24-20260816/status.summary.json`：2356 / 110 |

关闭顺序：`#19 → #22 → #23 → #24`，`#20 → #21`，`#21 + #24 → #18`。

## #47–#50

| 票 | 在本收口中的角色 |
| --- | --- |
| #47 | 真实 wrapper 上的 `leaf-delete-failed` 失败合同。关 #21 只引它的 `leaf-delete-failed.json` exit 1 |
| #48 | Status 在 policy 拒绝后仍只读观测历史事务。**有意 OPEN**。42 条 purged+manual-review 继续 blocking，不要 Archive |
| #49 | Status 冷启动 SLA。**有意 OPEN**。#26–#43 不覆盖 Status |
| #50 | 把将引用的证据发布到默认分支。本评论假定该发布与独立回读已完成 |

索引：`reports/safe-tree-delete-issue47-20260816/CLOSEABLE.md`、`reports/safe-tree-delete-issue50-20260816/MANIFEST.md`、`reports/safe-tree-delete-issue50-20260816/CLOSEABLE.md`。

## 剩余 residual（#24 live）

```text
2356 = 2244 terminal + 87 manual-review + 23 inconsistent + 1 recoverable + 1 purge-resumable
110  = 51 plan-only + 1 missing-plan + 42 #48 purged-MR + 10 planned-namespace + 5 v1 + 1 historical-v2
```

另有 leftover `0ab1e1b6`（`purge-resumable`，不在 blocking），属 **#45** 清空集，本收口未 Purge。#45 **不在本票关闭范围内**。

## 父 spec 用户故事（摘要）

已兑现：合格 terminal 退出 blocking；归档不删 evidence；单笔确认、判据不放宽、policy 仍 v4；5 条 v1 仍可见；`leaf-delete-failed` 经 wrapper 为非零；12/69 条「未解析」已归因（现役 both-null=52，另 42 条由 #48 读成 purged）。

未按原文兑现、但判定合理或已移交：

- `complete=true` / `ready=true`：不应再要求。110 条是真实待处理。
- Status 日常耗时显著下降：502s → 493.768s，扫描量更大。交给 **#49**。

## 引用（仓库相对路径）

- `reports/safe-tree-delete-issue24-20260816/status.summary.json`
- `reports/safe-tree-delete-issue24-20260816/comparison-vs-baseline-19.json`
- `reports/safe-tree-delete-issue24-20260816/REPORT.md`
- `reports/safe-tree-delete-issue23-20260816/REPORT.md`
- `reports/safe-tree-delete-issue55-20260816/leaf-delete-failed.json`
- `reports/safe-tree-delete-issue55-20260816/identity.json`
- `reports/safe-tree-delete-issue47-20260816/CLOSEABLE.md`
- `reports/safe-tree-delete-issue50-20260816/MANIFEST.md`
- `reports/safe-tree-delete-issue50-20260816/CLOSEABLE.md`
