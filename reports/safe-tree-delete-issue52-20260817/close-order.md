---
type: snapshot
title: Issue #52 关票顺序（草稿关口，未执行）
tags: [safe-tree-delete, issue-52, closeout]
intent: 写明授权后的评论与关闭顺序；本关口未 gh comment/close
---

# 关票顺序

本文件是编排，不发到 GitHub。本关口**未**执行任何 `gh` 写入。

前提（#52 AC，本关口未满足）：#50 已发布到默认分支并独立回读；#47 的 closure-grade 证据可从默认分支按相对路径读取。在此之前不得发评论、不得 `gh close`。

## DAG

```text
#19（已 CLOSED）
        │
        ▼
      #22  ──►  #23  ──►  #24 ──┐
                                 ├──►  #18  ──►  #52 自关
#20  ──►  #21  ─────────────────┘
```

写成一条可执行顺序：

1. `#19`（已关）→ `#22` → `#23` → `#24`
2. `#20` → `#21`（可与上链并行，但 `#21` 必须在 `#20` 关闭之后）
3. `#21` + `#24` → `#18`
4. `#18` 关闭并回读全部状态与评论 → `#52` 自关

`#11` / `#17` 已 CLOSED：只发最终判定评论，**保持 CLOSED**。建议在 `#24` 评论之后发，因为判定引用的是 #24 live Status。

**不关闭、不修改 `#45`。** leftover `0ab1e1b6` 与缺 `leafStreamSetV1` 的在途事务仍属 `#45`。

`#48` / `#49` 有意保持 OPEN，不是本收口关闭对象。

## 每票动作

| 顺序 | 票 | 先发评论 | 然后 | 现役计数来源 |
| ---: | --- | --- | --- | --- |
| 0 | #19 | — | 已 CLOSED | 归档前基线 `reports/safe-tree-delete-status-baseline-20260810.json` |
| 并行 A1 | #22 | `comment-22.md` | `gh close` | #24 live：2356 / 110；不要 02:17 |
| 并行 A2 | #23 | `comment-23.md` | `gh close` | 调查=02:17；现役计数以 #24 为准 |
| 并行 A3 | #24 | `comment-24.md` | `gh close` | `status.summary.json` 2356 / 110 |
| 并行 B1 | #20 | `comment-20.md` | `gh close` | 只主张转发 |
| 并行 B2 | #21 | `comment-21.md` | `gh close` | 非零主证据只有 `leaf-delete-failed.json` exit 1 |
| 后置 | #11 | `comment-11.md` | 保持 CLOSED | 同 #24 |
| 后置 | #17 | `comment-17.md` | 保持 CLOSED | 同 #24 |
| 汇合 | #18 | `comment-18.md` | 仅当 #20–#24 均 CLOSED 且评论可见 | 汇总 #20–#24、#47–#50 |
| 最后 | #52 | `comment-52.md` | 自关；不关 #45 | 回读上述评论与状态 |

`#22` 与 `#20` 无互相阻塞，可以并行发评论并关闭。`#23` 必须在 `#22` 关闭之后。`#24` 必须在 `#22` 与 `#23` 都关闭之后。`#21` 必须在 `#20` 关闭之后。`#18` 必须在 `#21` 与 `#24` 都关闭之后。

## 本关口未做

- 未 `gh issue comment`
- 未 `gh issue close`
- 未 commit / push
- 未发布 #50
