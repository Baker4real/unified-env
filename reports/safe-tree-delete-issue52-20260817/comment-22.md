## 结论（先于关闭）

#22 的归档执行可以关闭。合格 terminal 已退出 `blockingRecords`。现役 live 计数是 **operations=2356**、**blocking=110**，来自 #24 的 2026-08-16T14:23:31Z Status，**不要用 02:17 的 2323/110**。

`complete=false` **不是**本票失败，也**不要**要求 `complete=true`。票面「降至约 79」是 #19 当时的投影残差，不是现役目标。

## Acceptance criteria

| AC | 结论 | 依据 |
| --- | --- | --- |
| 候选集在执行时重新推导，不复用 #19 快照 | **满足** | 20260814 已按当时 live 候选逐条 Archive。`reports/safe-tree-delete-issue22-20260815/archive-summary.json`：其后再次推导 `liveCandidateCount=0`，因此**没有**新的 Archive 写入 |
| 归档后 blocking 从 1674 降至约 79，偏差有解释 | **满足（用现役 110，不用 79）** | #19 基线 blocking=1674。现役 **110**（#24）。79 是过期投影。110 = 51 plan-only + 1 missing-plan + 42 条 #48 purged+manual-review + 10 planned-namespace + 5 v1 + 1 历史 v2 |
| 5 条 v1 与 1 条历史 v2 仍在视图，未被归档 | **满足** | `reports/safe-tree-delete-issue24-20260816/status.summary.json` 仍列出这 6 个 operationId |
| 归档过程零 evidence 文件删除或重写 | **满足** | #22 后段 live 未再 Archive。Status 只读 |
| 单条失败不中断其余；逐条结果可读 | **历史执行已满足**；后段候选为 0 | 未新增 `BatchArchive`。后段无逐条循环可跑 |
| 每条归档留下含时点的可追溯证据 | **历史执行已满足** | 后段无新 marker。11 条 `journalStatus=not-applicable` 的 live purged **不是**漏归档，不要补写 marker（见 `reports/safe-tree-delete-issue22-comment-20260815/REPORT.md`） |
| 未新增 `BatchArchive` 或等价批量入口 | **满足** | `protection-check.json`：`noBatchArchive.modes` 仍是既有 Mode 集合 |
| 归档判据代码未被改动 | **满足（本票未改）** | 本收口未改生产实现 |
| 证据根三层保护未改动 | **满足** | `protection-check.json`：denylist、`minimumDescendantDepth=2`、retention `Manual=true` |
| policy schema 仍为 v4，未激活 v5 | **满足** | #24 live `policySchemaVersion=4` |
| 批量归档错误隔离有 fixture 级回归 | **既有 ControlPlane 覆盖** | 本收口不重跑 fixture 来关票 |
| 既有全部 safe-tree-delete 测试保持通过 | **有已知 waiver** | #35 FileSystem 为范围外 waiver。不得用过期 fixture 计数冒充现役 Status |

## 现役计数（#24，不是 02:17）

| 项 | 值 |
| --- | ---: |
| `capturedAtUtc` | 2026-08-16T14:23:31Z |
| operations | **2356** |
| `blockingRecords` | **110** |
| `lifecycle=terminal` | 2244 |
| `complete` | false（合理，不要求翻 true） |

42 条 `purged` + `manual-review` 是 #48 的 policy 拒绝观测，**不是**本票漏归档的已确认 terminal。不要对它们跑 Archive。

先前已发评论副本 `reports/safe-tree-delete-closeout-20260816/github-comments/issue-22.md` 使用 02:17 计数；**本条取代那些现役数字**。

## 引用（仓库相对路径）

- `reports/safe-tree-delete-issue24-20260816/status.summary.json`（现役 2356/110）
- `reports/safe-tree-delete-issue24-20260816/comparison-vs-baseline-19.json`
- `reports/safe-tree-delete-issue24-20260816/REPORT.md`
- `reports/safe-tree-delete-issue22-20260815/REPORT.md`
- `reports/safe-tree-delete-issue22-20260815/acceptance.json`
- `reports/safe-tree-delete-issue22-20260815/archive-summary.json`
- `reports/safe-tree-delete-issue22-20260815/protection-check.json`
- `reports/safe-tree-delete-issue22-comment-20260815/REPORT.md`
- `reports/safe-tree-delete-closeout-20260816/github-comments/issue-22.md`（旧评论；计数已过期）
- `reports/safe-tree-delete-status-baseline-20260810.json`
