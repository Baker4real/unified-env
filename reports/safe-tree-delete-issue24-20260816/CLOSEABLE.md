# Issue #24 AC 对照

本文件只解释本证据目录与本次 live Status。不是 GitHub 关单授权，不是对 leftover `0ab1e1b6` 的处置授权。未 commit / push / comment / close。

判定 Status：`capturedAtUtc=2026-08-16T14:23:31.9663166+00:00`，exit 0，墙钟 493.768s。证据见 `status-utf8.json`、`comparison-vs-baseline-19.json`、`REPORT.md`。

| AC | 状态 | 证据 |
| --- | --- | --- |
| 归档后的生产 Status 输出留存到受版本控制位置，与 #19 基线同格式可对比 | **满足** | `status-raw.json`、`status-utf8.json`、`status-raw.meta.json`、`comparison-vs-baseline-19.json` |
| 逐项列出与归档前基线的差异：耗时、扫描量、哈希量、记录数、blockingRecords、lifecycle 分布 | **满足** | `comparison-vs-baseline-19.json` 与 `REPORT.md` 对比表 |
| 给出 `complete` 与 `migrationReadiness.ready` 的最终取值及其是否合理的判断 | **满足** | 均为 `false`，判定合理；见 `REPORT.md` 结论表 |
| 若 `complete` 仍为 `false`，逐条说明剩余阻塞项为何是真实待处理事项而非账面噪声 | **满足** | 110 条 blocking：#48 purged+MR 42、plan-only both-null 51+acl 1、v1×5、历史 v2×1、namespace 10。leftover 可识别为 `purge-resumable`，**不在** blocking。smoke 新 6 条均为 terminal |
| 给出耗时是否满足「日常清理前顺手确认」；若不满足，产出独立性能立项并说明主要成本构成 | **满足（指向已有票）** | 不满足（493.768s）。**未** `gh issue create`。指向已存在的 #49。成本：全量枚举 + 重哈希 + 2244 条 terminal-archive 认证。明确 #26–#43 不覆盖 Status 冷启动 |
| 用与父 spec 同类的分解算式验证收敛（不能套 1742 或 1674→79） | **满足** | `2356 = 2244 + 87 + 23 + 1 + 1`；`110 = 51+1+42+10+5+1` |
| 5 条 v1 未终结与 1 条 v2 未终结仍可从 Status 输出直接识别 | **满足** | `live-inspect.json` 列出 5 个 v1 operationId（路径与 #19 基线一致）+ `20260805T083256Z-1ba06d2f-…`。leftover `0ab1e1b6` 额外可识别为 v2 `purging` / `purge-resumable` |
| 运行生产 smoke 测试 | **满足（编排授权引用 #55；本票未执行 live smoke）** | 按本票说明，引用 `reports/safe-tree-delete-issue55-20260816/summary.json`（exit 0，407.492s）与 `leaf-delete-failed.json` 即满足该 AC。本票未再跑 ProductionSmoke。判定 Status 是该 smoke 之后的新跑 |
| 判定结论回写到 #17 与 #11 | **本关口只完成草稿** | `github-comment-issue-17.md`、`github-comment-issue-11.md`。**未** `gh issue comment`。两票已 CLOSED |
| 只使用只读 Status 模式，对生产证据根零写入 | **满足** | 仅 `-Mode Status -Json`。`evidence-status-write-compare.json`：`zeroWrite=true`。leftover SHA 未变 |

未关闭 #24。未处理 leftover。未改生产代码。
