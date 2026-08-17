---
type: snapshot
title: Issue #50 证据包清单（工作区，未发布）
tags: [safe-tree-delete, issue-50, evidence]
intent: 列出复算 #22–#24 与关闭 #20/#21/#47/#55 所需的相对仓库路径；本关口停在清单+工作区文件，不 commit
---

# Issue #50 证据包清单

本目录是 GitHub #50 的工作区证据包索引。**未** `git add` / commit / push。远端默认分支回读 **未做**。不要把本机绝对路径当成引用真源。

权威计数与哈希以 JSON 为准，不以过期 Markdown 为准。尤其不要用 `reports/safe-tree-delete-issue55-20260816/CLOSEABLE.md` 的墙钟 382.981 / operations 2341；现役是 `summary.json` 的 407.492s / 2350。

## 包边界

| 包 | 采集时点 (UTC) | 关键计数 | 哈希或 operationId 绑定 | 可复算入口（相对路径） |
| --- | --- | --- | --- | --- |
| ProductionSmoke 真源 | 工作树当前文件（#55/#21 切片） | 测试文件本身 | 随 commit 计算 | `tests/Test-CodexSafeTreeDeleteProductionSmoke.ps1` |
| #19 基线 | 2026-08-10T15:04:00Z | 归档前 Status | 已在默认分支 | `reports/safe-tree-delete-status-baseline-20260810.json` |
| #55 smoke | 2026-08-16T13:43:49Z | exit 0；407.492s；invocations=20；Status ops=2350 | identity cmd `45aeadf7…` ps1 `636cb140…`；stdout SHA `1d069f8a…`；USN digest `094ffc0f…`；绑定 `operations[].operationId` | **禁止本关口重跑** 同一测试文件 |
| #21 撤转发 | 同一次 smoke | revert exit 0；wrapper 吞非零 | backup SHA = 转发 SHA `636cb140…` | `reports/safe-tree-delete-issue21-20260816/revert-forwarding.json` |
| #22 归档执行 | 2026-08-14T17:59:04Z | ops=2321；blocking=110；合格候选=0 | utf8 SHA `59cd7235…`（raw SHA 在 meta） | `reports/safe-tree-delete-issue22-20260815/summarize-status.py`（离线） |
| closeout 02:17 + 已发评论 | 2026-08-16T02:17:18Z | ops=2323；blocking=110 | 评论引用 raw SHA `0c7e5023…` 记在 meta；本包保留 utf8 | `reports/safe-tree-delete-closeout-20260816/summarize-status.py`（离线） |
| #23 调查 | 基于 02:17 utf8 | both-null=52 | 引用 closeout `status-raw.utf8.json` | `reports/safe-tree-delete-issue23-20260816/REPORT.md` |
| #24 live Status | 2026-08-16T14:23:31Z | ops=2356；blocking=110；complete=false；493.768s | utf8 SHA `3dc60707…`（`status.summary.json` `sourceStatusSha256`） | `reports/safe-tree-delete-issue24-20260816/summarize_status.py`（离线） |
| #47 索引 | 只读引用 #55/#21 | 非零主证据 = leaf-delete-failed exit 1 | 见 evidence-index.md | `reports/safe-tree-delete-issue47-20260816/evidence-index.md` |
| #35 livefs | 2026-08-15 | 已发评论引用该目录 | 目录内 meta | `reports/safe-tree-delete-issue35-livefs-20260815/` |

#24 取代 #23 的现役计数。#23 仍要随包提交，因为调查正文指向 02:17 快照。

## 排除大类（详见 `exclude.json`）

1. heartbeat
2. lock-acquired / lock-release / lock-holder.log
3. 已有 utf8 派生的过大 raw Status（closeout / #22 / #24）
4. leftover quarantine payload（`reports/.codex-safe-delete-0ab1e1b6-…` 等）
5. 生产 evidence 根 dump（#24 `evidence-before.json` / `evidence-after.json`）
6. smoke livefail payload 目录
7. 他人 WIP（Serena、Sub2API、policy、`CodexSafeTreeDelete.ps1`、hooks）
8. 整个 `reports/` 一把梭
9. `D:\Codex\.codex\run-evidence\safe-tree-delete\` 事务（不复制进 git）

## 已发 GitHub 评论

副本：`reports/safe-tree-delete-closeout-20260816/github-comments/`。`include.json` 列出评论引用的相对路径，避免远端评论断链。#46 引用的脏 `managed/codex-hooks/manifest.json` **不**纳入本包。

## 本关口未做

- git add / commit / push / 独立回读默认分支哈希
- 重跑 Status / ProductionSmoke / Archive / Purge / Restore
- 修改生产实现、wrappers、policy、hooks
- 把 leftover 清空

## 模块验证

本关口未重跑 host-safety 全量。#35 FileSystem 为已知 waiver。自检：`python reports/safe-tree-delete-issue50-20260816/verify-issue50-pack.py`
