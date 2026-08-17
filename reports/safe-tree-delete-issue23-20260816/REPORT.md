---
type: snapshot
title: Issue #23 只读调查（2026-08-16 主 Agent 落盘）
tags: [safe-tree-delete, issue-23, status]
intent: 把 #23 对未解析事务的分组结论落到受版本控制位置；不是 live Status，也不是 Archive/Purge 授权
---

# Issue #23 只读调查

对照快照：`reports/safe-tree-delete-closeout-20260816/status-raw.utf8.json`（`capturedAtUtc=2026-08-16T02:17:18Z`，`policySha256=01a22918…`，与当时及本波核验时的 `managed/safe-tree-delete/policy.json` 一致）。未调用 live wrapper。leftover `0ab1e1b6` 与 #54 缺 `leafStreamSetV1` 的在途事务不在本快照、也不在 both-null 集合里。

调查节点：[Implement issue 23](a8360310-e292-4726-8637-19d20b7d370a)。主 Agent 复验了 both-null 计数、7 个样本磁盘布局和当前 policy SHA。

## 已核验计数

| 项 | 值 |
| --- | ---: |
| operations | 2323 |
| `transactionSchemaVersion` 与 `transactionStatus` 均为 null | **52** |
| 其中 leftover `0ab1e1b6` | 0 |
| `complete` | false |

票面「69 条 schema+status 均为 null」不是 02:17 事实。这 52 条 **全部没有 `transaction.json`**（过期计划或有意残缺），不是「事务文档在但解析器读不出来」。

## 组 1（capability root 不在 allowlist）

票面原 34 条是更早基线。02:17 带该错误串的记录是 **40** 条：both-null **2**、`transactionStatus=purged` **38**。子代理把「原 34 条里 33 条已被 #48 读成 v2 purged」当作票面映射，方向对（解析器缺口已由 #48 闭合），但 **不要把 33+2 当成 02:17 的集合大小**。

剩余 2 条 both-null 样本 `20260805T153744Z-58046b4e-…`：磁盘只有 `plan.json`。同 root 稍后 `20260805T153928Z-163b53ca-…` 已是 v2 `purged`。已观测的 38 条必须继续 blocking（#48），本波不 Archive。不要把已撤销 ephemeral root 写回 allowlist。

不全是退役项目：明确退役路径只有雷达天梯 / okf-frontmatter；其余是仍在项目上的一次性清理根，现场写入后从工作树撤销、从未进 git。

## 其余组（与子代理一致，样本已对磁盘）

| 组 | 02:17 | 处置 |
| --- | ---: | --- |
| planned tree manifest 漂移 | 17（票面 15 + 2 条 08-12 bin） | 保留原状，不是 Archive 对象 |
| planned namespace 不一致 | 13 条无事务计划（不是票面原 12 条事务解析失败） | 保留原状 |
| 同上 + policy SHA 漂移 | 18 = 原 6 + 原 12 因 SHA 翻转多一条错误 | 保留原状 |
| 未达最小后代深度 | 1 | 保留原状；不要把 `codex-run-evidence` 最小深度改回 1 |
| 缺 plan.json | 1（`acl-capability-probe-20260801`，目录只有 `probe.ps1`） | **保留原状，不删除** |

无数据丢失风险。无需要人工处理的真实不一致。本票 **不再需要新代码**；把无事务过期计划扩成 Archive 会放宽合同，禁止。

## `complete=false`

仍应保持 false。02:17 `blockingRecords=110` 含本票 52 条 plan-only 未解析、42 条 #48 已观测但仍 manual-review 的 purged、以及未终结在途。归档合格 terminal 也不蕴含 `complete=true`。

## 未做

未跑 live Status，未 Archive，未 `gh issue close/comment`，未把 02:17 计数写成 leftover 之后的 live 事实。
