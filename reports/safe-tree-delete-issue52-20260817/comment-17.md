#17 已 CLOSED。这是最终判定回写，**保持 CLOSED**。

归档能力已兑现：2026-08-16T14:23:31Z 生产只读 Status（#24，smoke 之后新跑）看到 `lifecycle=terminal` **2244** 条，均已退出 `blockingRecords`。证据根零写入。未再 Archive。

`complete=false`、`migrationReadiness.ready=false` 是**合理终态**，不是归档没做完。权威 spec 已明确：归档合格 terminal 不蕴含 `complete=true`。本次 live `blockingRecords=110`，都能归到真实待处理（#48 的 purged+manual-review、plan-only both-null、5 条 v1 未终结、1 条历史 v2、ui-references namespace 不一致、acl probe）。另有 leftover `0ab1e1b6`（v2 `purging` / `purge-resumable`）可从 Status 直接识别，本波未 Purge。

#17 原文 AC「归档全部合格历史记录后 complete 为 true」已被后续 spec 否定，不应再当作关单条件。

Status 日常「顺手确认」仍约 8.2 分钟，不满足秒级。性能由已存在的 **#49** 跟进，不新开 GitHub issue。**#26–#43 不覆盖 Status 冷启动。**

引用（仓库相对路径）：

- `reports/safe-tree-delete-issue24-20260816/status.summary.json`
- `reports/safe-tree-delete-issue24-20260816/comparison-vs-baseline-19.json`
- `reports/safe-tree-delete-issue24-20260816/REPORT.md`
