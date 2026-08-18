## 结论（先于关闭）

#24 可以关闭。2026-08-16T14:23:31Z 生产只读 Status 给出最终判定：`complete=false`、`migrationReadiness.ready=false` **都合理**。归档合格 terminal 不蕴含 `complete=true`。剩余 110 条 blocking 全部可分类，不是账面噪声。

日常「顺手确认」仍约 **8.2 分钟**（墙钟 493.768s，`elapsedMs=491363`），不满足秒级。不新建票；跟进已存在的 **#49**。**#26–#43 不覆盖 Status 冷启动。**

#23 的归因结论仍然成立：52 条 both-null 是过期/残缺计划，不是解析器读不出已有事务。现役 operations / blocking 以本次 live 为准，不要用 02:17 的 2323/110。

## Acceptance criteria

| AC | 结论 | 依据 |
| --- | --- | --- |
| 归档后生产 Status 留存到受版本控制位置，与 #19 基线同格式可对比 | **满足**（待 #50 上默认分支） | `status-utf8.json` + `status.summary.json`；对比 `comparison-vs-baseline-19.json`；基线 `reports/safe-tree-delete-status-baseline-20260810.json` |
| 逐项列出与归档前基线的差异 | **满足** | 见下表 |
| 给出 `complete` 与 `ready` 的最终取值及是否合理 | **满足** | 均为 `false`，合理 |
| 若 `complete` 仍为 false，说明剩余阻塞为何是真实待处理 | **满足** | 110 条全部分类，见下 |
| 耗时是否满足日常顺手确认；不满足则独立性能立项 | **不满足；指向已有 #49** | 493.768s。未 `gh issue create`。成本是全量枚举 + 重哈希 + 2244 条 terminal-archive 认证，不是这 110 条 blocking |
| 用同类分解验证收敛（不能套 1742 或 1674→79） | **满足** | `2356 = 2244 + 87 + 23 + 1 + 1`；`110 = 51+1+42+10+5+1` |
| 5 条 v1 与 1 条历史 v2 仍可从 Status 直接识别 | **满足** | `live-inspect.json` / `status.summary.json` |
| 运行生产 smoke | **满足（引用 #55，本票未再跑）** | `reports/safe-tree-delete-issue55-20260816/summary.json`：`ok=true`，墙钟 407.492s，`generatedAtUtc=2026-08-16T13:43:49Z`。判定 Status 在该 smoke **之后** |
| 判定回写 #17 与 #11 | **草稿随 #52 发出；两票保持 CLOSED** | 见 #11 / #17 评论 |
| 只读 Status，生产证据根零写入 | **满足** | 仅 `-Mode Status -Json`。`evidence-status-write-compare.json`：`zeroWrite=true` |

## 与 #19 基线

| 指标 | #19 归档前 | 本次 live | 差 |
| --- | ---: | ---: | ---: |
| `elapsedMs` | 501018 | 491363 | −9655 |
| 墙钟秒 | 502 | 493.768 | −8.232 |
| `entriesScanned` | 4815 | 6622 | +1807 |
| `bytesHashed` | ≈1.63GB | ≈1.81GB | +0.18GB |
| operations | 1980 | **2356** | +376 |
| `blockingRecords` | 1674 | **110** | −1564 |
| `complete` | false | **false** | 不变 |
| `lifecycle=terminal` | 306 | **2244** | +1938 |

不要把父 spec 的 `1742 = 1661 + 80 + 1` 或 #19 投影 residual 79 写成现役算式。

## 110 条 blocking 为何真实

```text
2356 = 2244 terminal + 87 manual-review + 23 inconsistent + 1 recoverable + 1 purge-resumable
110  = 87 + 23
110  = 51 plan-only-both-null + 1 missing-plan + 42 purged-manual-review
       + 10 planned-namespace + 5 v1-unterminated + 1 historical-v2
```

- **42** 条 `purged` + `manual-review`：#48 只读观测成功，**不是** Archive 候选。
- **52** 条 both-null（51 plan-only + `acl-capability-probe-20260801`）：#23 已归因，保留原状。
- **5** 条 v1 未终结：路径与 #19 基线一致，无受支持写路径。
- **1** 条历史 v2：`20260805T083256Z-1ba06d2f-…`，policy 漂移。
- **10** 条 planned-namespace：2026-08-13 时钟倒计时 `assets\ui-references\…`，target 与 quarantine 都不在。

leftover `0ab1e1b6` 可识别为 `purge-resumable` / `purging`，**不在** blocking。`leftover-after.json` 核验 SHA 未变。本票未 Purge。属 #45/#50 清空集。

## #26–#43 与 #49

#26–#43 是 Plan/Apply/Purge 性能系列，不覆盖 Status 冷启动，也不消费 Status 的 invocation-local cache。Status 日常可用由 **#49** 独立跟进。

## 引用（仓库相对路径）

- `reports/safe-tree-delete-issue24-20260816/status.summary.json`（`sourceStatusSha256=3dc60707…`，`operationCount=2356`，`blockingRecordCount=110`）
- `reports/safe-tree-delete-issue24-20260816/status-utf8.json`
- `reports/safe-tree-delete-issue24-20260816/comparison-vs-baseline-19.json`
- `reports/safe-tree-delete-issue24-20260816/REPORT.md`
- `reports/safe-tree-delete-issue24-20260816/live-recount.json`
- `reports/safe-tree-delete-issue24-20260816/live-inspect.json`
- `reports/safe-tree-delete-issue24-20260816/evidence-status-write-compare.json`
- `reports/safe-tree-delete-issue24-20260816/leftover-after.json`
- `reports/safe-tree-delete-status-baseline-20260810.json`
- `reports/safe-tree-delete-issue23-20260816/REPORT.md`
- `reports/safe-tree-delete-issue55-20260816/summary.json`
