---
type: snapshot
title: Issue #52 关票评论草稿对照（2026-08-17）
tags: [safe-tree-delete, issue-52, closeout]
intent: 对照 GitHub #52 Acceptance criteria；本关口只写评论草稿，不发布、不关票、不 commit
---

# Issue #52 AC 对照

本目录只准备将发布到 GitHub 的评论稿。**不是** `gh issue comment` / `gh issue close` / `gh issue edit` 授权，**不是** leftover `0ab1e1b6` 的 Purge/Restore 授权，**不是** commit / push 授权。

计数、退出码、哈希一律以已打开的 JSON 为准，不以过期 Markdown 为准。现役 Status 计数以 `reports/safe-tree-delete-issue24-20260816/status.summary.json` 为准（`operations=2356`，`blockingRecordCount=110`，`complete=false`）。不要用 02:17 closeout（2323/110）或 #23 调查墙钟当现役。

## 本关口判定

| 项 | 结论 |
| --- | --- |
| 评论草稿 | **已写**（见下方清单） |
| 默认分支发布（#50 publish） | **未做** |
| `gh issue comment` / `gh issue close` | **未做** |
| commit / push | **未做** |
| leftover `0ab1e1b6` Purge | **未做**（禁止） |
| #45 | **不关、不改** |

**实现关口（本地草稿）：可交审。**
**GitHub 关闭条件：BLOCKED on 用户授权的 #50 publish + 评论权。**
#52 正文要求「开始前回读 #47 与 #50 已完成，所有将引用的版本化证据可从仓库默认分支读取」。本关口只证明工作区路径已列入 `reports/safe-tree-delete-issue50-20260816/STAGED-FILE-LIST.txt`；远端默认可读与独立回读哈希 **未做**。

## #52 Acceptance criteria

| AC | 本关口 | 证据 / 草稿 |
| --- | --- | --- |
| 开始前回读 #47 与 #50 已完成，将引用的版本化证据可从默认分支读取 | **工作区可读**；默认分支 **未做** | 只读打开了 #47 `CLOSEABLE.md` / `evidence-index.md`、#50 `MANIFEST.md` / `STAGED-FILE-LIST.txt` / `CLOSEABLE.md`、#55 `leaf-delete-failed.json`（`exitCode=1`）。未 `gh close` #47/#50，未独立回读默认分支 |
| #23 先收到逐项对照 AC 的结论评论，引用调查证据和后续实现票 #48；区分解析器覆盖缺口、无害过期 plan、真实 residual 与 unknown | **草稿已写**；未发 | `comment-23.md` |
| 已关闭的 #17/#11 收到最终判定评论且保持 CLOSED；说明归档已兑现、`complete=false` 是合理终态、Status 日常可用由 #49 跟进 | **草稿已写**；未发 | `comment-11.md`、`comment-17.md`。两票 GitHub 状态已是 CLOSED |
| #24 结论评论引用版本化 Status、#23 结论和 #49；明确 #26–#43 不覆盖 Status 性能；先评论后关闭 | **草稿已写**；未发 | `comment-24.md` |
| #20、#21、#22 各自先收到逐项验收结论再关闭；#21 只能引用 #47 的真实 wrapper 非零退出码 | **草稿已写**；未发 | `comment-20.md`（只主张转发，不吞并 #47/#55）。`comment-21.md` 的非零主证据只有 `reports/safe-tree-delete-issue55-20260816/leaf-delete-failed.json` 的 `exitCode=1`。`comment-22.md` 用 #24 live 2356/110 |
| #22 使用执行时重新读取的 live 计数，不复用过期历史计数，也不要求 `complete=true` | **草稿已写** | `comment-22.md` 只用 #24 `status.summary.json` 的 2356/110；明确不要求 `complete=true`；不用 02:17 |
| 关闭顺序 #19 → #22 → #23 → #24、#20 → #21、#21 + #24 → #18；#18 仅在 #20–#24 全部 CLOSED 且评论可见后关闭 | **顺序稿已写**；未执行 | `close-order.md`。#19 已 CLOSED。本关口未 `gh close` 其余票 |
| #18 最终评论汇总 #20–#24、#47–#50 和剩余 residual；明确 #48/#49 是有意开放的范围外 successor | **草稿已写**；未发 | `comment-18.md` |
| #18 关闭并再次回读后，#52 写入可追溯完成评论并自关；不关闭或修改 #45 | **自关草稿已写**；未发、未自关 | `comment-52.md`。#45 保持不动 |

## 草稿文件清单

| 文件 | 将发到 | 本关口是否已 `gh` |
| --- | --- | --- |
| `comment-23.md` | #23（先于关闭） | 未发 |
| `comment-24.md` | #24（先于关闭） | 未发 |
| `comment-11.md` | #11（保持 CLOSED） | 未发 |
| `comment-17.md` | #17（保持 CLOSED） | 未发 |
| `comment-20.md` | #20（先于关闭） | 未发 |
| `comment-21.md` | #21（先于关闭） | 未发 |
| `comment-22.md` | #22（先于关闭） | 未发 |
| `comment-18.md` | #18（先于关闭） | 未发 |
| `comment-52.md` | #52（自关） | 未发 |
| `close-order.md` | 编排，不发 GitHub | — |
| `CLOSEABLE.md` | 本对照，不发 GitHub | — |

## #21 非零主证据

关 #21 的评论**只**把下面这一条当作非零主证据：

- `reports/safe-tree-delete-issue55-20260816/leaf-delete-failed.json` → 已打开，`exitCode=1`，`purged=false`，`refusalReason=leaf-delete-failed`，`productionJsonObtained=true`

同一次调用的配对文件（`fail-purge-leaf-delete.meta.json` / `.stdout.txt`）只标为配对，不另立第二条非零主证据。

明确**不是** #21 非零主证据：

| 文件 | 已打开字段 | 用途 |
| --- | --- | --- |
| `reports/safe-tree-delete-issue21-20260816/revert-forwarding.json` | `exitCode=0`，`wrapperSwallowedNonzero=true` | 仅 #21 负向切片 |
| `reports/safe-tree-delete-issue55-20260816/summary.json` | `ok=true` | 套件收口，不能替代 exit 1 |
| fixture / mock | — | 禁止 |

## 各评论将引用的相对路径 vs #50 STAGED

下列路径均已出现在 `reports/safe-tree-delete-issue50-20260816/STAGED-FILE-LIST.txt`。本关口**没有**发明 STAGED 之外的证据文件。

### 共用 / 索引

- `reports/safe-tree-delete-issue50-20260816/STAGED-FILE-LIST.txt`
- `reports/safe-tree-delete-issue50-20260816/MANIFEST.md`
- `reports/safe-tree-delete-issue50-20260816/CLOSEABLE.md`
- `reports/safe-tree-delete-issue47-20260816/CLOSEABLE.md`
- `reports/safe-tree-delete-issue47-20260816/evidence-index.md`

### `comment-23.md`

- `reports/safe-tree-delete-issue23-20260816/REPORT.md`
- `reports/safe-tree-delete-closeout-20260816/status-raw.utf8.json`
- `reports/safe-tree-delete-issue24-20260816/status.summary.json`
- `reports/safe-tree-delete-issue24-20260816/REPORT.md`

### `comment-24.md`

- `reports/safe-tree-delete-issue24-20260816/status.summary.json`
- `reports/safe-tree-delete-issue24-20260816/comparison-vs-baseline-19.json`
- `reports/safe-tree-delete-issue24-20260816/REPORT.md`
- `reports/safe-tree-delete-issue24-20260816/status-utf8.json`
- `reports/safe-tree-delete-issue24-20260816/evidence-status-write-compare.json`
- `reports/safe-tree-delete-issue24-20260816/live-inspect.json`
- `reports/safe-tree-delete-issue24-20260816/live-recount.json`
- `reports/safe-tree-delete-issue24-20260816/leftover-after.json`
- `reports/safe-tree-delete-status-baseline-20260810.json`
- `reports/safe-tree-delete-issue23-20260816/REPORT.md`
- `reports/safe-tree-delete-issue55-20260816/summary.json`

### `comment-11.md` / `comment-17.md`

- `reports/safe-tree-delete-issue24-20260816/status.summary.json`
- `reports/safe-tree-delete-issue24-20260816/comparison-vs-baseline-19.json`
- `reports/safe-tree-delete-issue24-20260816/REPORT.md`
- `reports/safe-tree-delete-issue24-20260816/github-comment-issue-11.md`（#11 底稿来源）
- `reports/safe-tree-delete-issue24-20260816/github-comment-issue-17.md`（#17 底稿来源）

### `comment-20.md`

- `reports/safe-tree-delete-issue55-20260816/identity.json`
- `reports/safe-tree-delete-issue55-20260816/archive-unconfirmed.meta.json`
- `reports/safe-tree-delete-issue55-20260816/archive-unconfirmed.stdout.txt`
- `reports/safe-tree-delete-closeout-20260816/github-comments/issue-20.md`
- `reports/safe-tree-delete-closeout-20260816/issue20-production-purge-fail.json`

不引用 `leaf-delete-failed.json` 作为本票吞并 #47/#55 的证明。

### `comment-21.md`

- `reports/safe-tree-delete-issue55-20260816/leaf-delete-failed.json`（**唯一非零主证据**）
- `reports/safe-tree-delete-issue55-20260816/fail-purge-leaf-delete.meta.json`（同一次调用配对）
- `reports/safe-tree-delete-issue55-20260816/fail-purge-leaf-delete.stdout.txt`（同一次调用配对）
- `reports/safe-tree-delete-issue21-20260816/revert-forwarding.json`（负向；`exitCode=0`）
- `reports/safe-tree-delete-issue55-20260816/archive-unconfirmed.meta.json`
- `reports/safe-tree-delete-issue55-20260816/archive-unconfirmed.stdout.txt`
- `tests/Test-CodexSafeTreeDeleteProductionSmoke.ps1`
- `reports/safe-tree-delete-issue47-20260816/evidence-index.md`
- `reports/safe-tree-delete-issue21-20260816/CLOSEABLE.md`

### `comment-22.md`

- `reports/safe-tree-delete-issue24-20260816/status.summary.json`
- `reports/safe-tree-delete-issue24-20260816/comparison-vs-baseline-19.json`
- `reports/safe-tree-delete-issue24-20260816/REPORT.md`
- `reports/safe-tree-delete-issue22-20260815/REPORT.md`
- `reports/safe-tree-delete-issue22-20260815/acceptance.json`
- `reports/safe-tree-delete-issue22-20260815/archive-summary.json`
- `reports/safe-tree-delete-issue22-20260815/protection-check.json`
- `reports/safe-tree-delete-issue22-comment-20260815/REPORT.md`
- `reports/safe-tree-delete-closeout-20260816/github-comments/issue-22.md`（旧评论；计数已过期，本稿取代）
- `reports/safe-tree-delete-status-baseline-20260810.json`

### `comment-18.md`

- 上述 #20–#24 / #47 / #50 路径的汇总引用
- `reports/safe-tree-delete-issue24-20260816/status.summary.json`
- `reports/safe-tree-delete-issue47-20260816/CLOSEABLE.md`
- `reports/safe-tree-delete-issue50-20260816/MANIFEST.md`
- `reports/safe-tree-delete-issue50-20260816/CLOSEABLE.md`

### `comment-52.md`

- 远端将引用已发 GitHub 评论 + #50 包内相对路径
- 不把本目录当作 #50 发布证据

## STAGED 缺口

| 路径 | 处理 |
| --- | --- |
| `reports/safe-tree-delete-issue52-20260817/*` | **预期不在 #50 STAGED**。本关口产物，不是发布证据。评论发到 GitHub 后以 issue comment 为真源 |
| #24 过大 raw Status（未入 #50 包） | **有意不引**。评论改引已入包的 `status-utf8.json` + `status.summary.json` |
| 权威 spec（已在默认分支） | **不是 #50 缺口**。评论只点名 spec，不当作本包新证据 |
| 生产脚本 / policy 源路径 | **有意不引**。#20 改引已入包的 `identity.json` |
| `reports/safe-tree-delete-issue55-20260816/CLOSEABLE.md` | **有意不引为计数真源**。墙钟/operations 与当前 JSON 不一致 |

未发现「评论必须引用、但 STAGED 没有、因而编造文件」的缺口。

## 未做（硬停止）

- `gh issue comment` / `gh issue close` / `gh issue edit`
- `git add` / commit / push
- 默认分支独立回读
- 改测试、生产实现、hooks、policy
- Purge leftover `0ab1e1b6`
- 关闭或修改 #45
