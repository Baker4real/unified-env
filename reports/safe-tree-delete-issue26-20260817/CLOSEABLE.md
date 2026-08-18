# CLOSEABLE.md — GitHub #26 性能史诗收口

这不是 GitHub 关单授权。本文只把 Plan/Apply/Purge 性能 DAG 的实现关口收成一份史诗结论。未 commit / push / comment / close #26。Status / `-Mode BatchPurge` 属 #49，不在本票。

## 关口结论

`DONE_WITH_CONCERNS`

17 张子票加 #54 的实现关口已齐：库、Plan 采集、Apply/Purge 会话哈希复用、uncertain、批量验证、夹具 coordinator / journal 监控、操作者指南都已落地。生产 Plan→Apply→Purge 未达票面 4–6x（#36 = 1.02x，#42 = 0.962x）。不要把 4x/6x 读成已上线。

生产 Purge **未接** `ParallelPurgeCoordinator`，仍走 HostSafety 串行删除。#40 夹具 DOP4=4.48x 是 `File.Delete` 夹具墙钟，不是删除加速，未计入生产倍率。

## 子票实现关口

| 票 | 关口 | 一句话事实 | 证据 |
| --- | --- | --- | --- |
| #27 | DONE | `FILE_ID_INFO` P/Invoke 与 `GetFileIdentityV2` 已进 `main`（`e2064a3`） | `scripts/lib/CodexSafeTreeDeleteFileIdentity.cs`；`tests/Test-CodexSafeTreeDeleteIdentityV2.ps1` |
| #28 | DONE | `FileIdentityV2` 按内容相等，可作缓存键 | 同上 IdentityV2 测试；`e2064a3` |
| #29 | DONE | `SessionHashCache` + `ComputeHashFromHandle`（seek 0 → 哈希 → seek 0）已进 `main` | `scripts/lib/CodexSafeTreeDeleteHashCache.cs`；`tests/Test-CodexSafeTreeDeleteHashCache.ps1` |
| #30 | DONE | `GetHashSafely`：`FileShare.None`、identity 门闩、缓存命中不读内容 | 同上 HashCache 源；`tests/Test-CodexSafeTreeDeleteHashSafely.ps1` |
| #31 | DONE | Plan 并列写出 `fileIdentitiesV2`；缺节旧 Plan 失败闭锁 | `scripts/lib/CodexSafeTreeDelete.ps1`；`tests/Test-CodexSafeTreeDeletePlanIdentityV2.ps1` |
| #32 | DONE_WITH_CONCERNS | Apply 已接 invocation-local `SessionHashCache`；10k×4KB = **0.868x** | `reports/safe-tree-delete-issue32-20260817/scale-10000.json`（349164 / 302992） |
| #33 | DONE_WITH_CONCERNS | Purge 已接 invocation-local `SessionHashCache`；10k×4KB = **0.921x** | `reports/safe-tree-delete-issue33-20260817/scale-10000.json`（224320 / 206496）；`CLOSEABLE.md` |
| #34 | DONE | 尚未 `commit-authorized` 的 freeze 按路径是否仍在分为 `pendingFiles` / `uncertainFiles`；uncertain 不得收成 `purged` | `reports/safe-tree-delete-issue34-20260817/CLOSEABLE.md` |
| #35 | waiver | FAT32 / 网络实卷 e2e 维护者 waiver，未提权验证 | `reports/safe-tree-delete-issue35-livefs-20260815/REPORT.md`；性能 spec「操作者指南」 |
| #36 | DONE_WITH_CONCERNS | 完整 Plan→Apply→Purge 10k×160KiB：527846 / 517444 = **1.02x**，未达 3x | `reports/safe-tree-delete-issue36-20260817/scale-phase1.json`（`metTarget=false`） |
| #37 | DONE_WITH_CONCERNS | Purge 先收集 `List<PurgeFileLeaf>` 再验证，删除仍走 HostSafety；10k×4KB = **1.02x** / **0.964x** | `reports/safe-tree-delete-issue37-20260817/scale-10000.json`（187157 / 190905 / 180384） |
| #38 | DONE | `ThreadJournalWriter` / `ThreadJournalOwner` 已落地；未接 Purge 热路径 | `reports/safe-tree-delete-issue38-20260817/CLOSEABLE.md` |
| #39 | DONE_WITH_CONCERNS | `ParallelPurgeCoordinator` 已落地（夹具 10k = 31339ms）；生产 Purge 未接线 | `reports/safe-tree-delete-issue39-20260817/CLOSEABLE.md`；`scale-10000.json` |
| #40 | DONE_WITH_CONCERNS | 夹具效率峰值 DOP4=**4.48x**（13255 / 59439）；不是生产删除加速 | `reports/safe-tree-delete-issue40-20260817/analysis.json` |
| #41 | DONE_WITH_CONCERNS | 夹具 10k journal overhead **18.659%**，`IsWithinTarget=false` | `reports/safe-tree-delete-issue41-20260817/scale-10000.json`（6144 / 32927） |
| #42 | DONE_WITH_CONCERNS | 生产路径 10k×4KB：513510 / 534034 = **0.962x**，未达 4x/6x | `reports/safe-tree-delete-issue42-20260817/scale-phase3.json`（`metTargetTypical=false`） |
| #43 | DONE_WITH_CONCERNS | 操作者指南已写入性能 spec；未另造第三份用户指南；未把 4–6x 写成已交付 | `reports/safe-tree-delete-issue43-20260817/CLOSEABLE.md` |
| #54 | DONE | Plan 写 `leafStreamSetV1`，Apply/Purge 在各自 live freeze 消费并发布 leaf disposition | `reports/safe-tree-delete-closeout-20260816/github-comments/issue-54.md`；`related-fixture-tests.json`（LeafStreamSet exit 0） |

#37 的 10k 墙钟测于一度尝试的 HostSafety collect-then-process，随后已撤回，未重跑。数字仍以该 JSON 为准。

## 硬数字核对

| 引用 | JSON | 文档数字 | 核对 |
| --- | --- | --- | --- |
| #36 | `reports/safe-tree-delete-issue36-20260817/scale-phase1.json` | 527846 / 517444 = 1.02x | 已读；`metTarget=false` |
| #42 | `reports/safe-tree-delete-issue42-20260817/scale-phase3.json` | 513510 / 534034 = 0.962x | 已读；`metTargetBest=false` / `metTargetTypical=false` |
| #32 | `reports/safe-tree-delete-issue32-20260817/scale-10000.json` | 0.868x | 已读 |
| #33 | `reports/safe-tree-delete-issue33-20260817/scale-10000.json` | 0.921x | 已读 |
| #37 | `reports/safe-tree-delete-issue37-20260817/scale-10000.json` | 1.02x / 0.964x | 已读 |
| #40 | `reports/safe-tree-delete-issue40-20260817/analysis.json` | DOP4=4.48x | 已读；`speedupVsDop1=4.484`；夹具 `File.Delete` |
| #41 | `reports/safe-tree-delete-issue41-20260817/scale-10000.json` | 18.659%，`IsWithinTarget=false` | 已读 |
| #35 | `reports/safe-tree-delete-issue35-livefs-20260815/REPORT.md` | waiver，未提权 | 与操作者指南一致 |

操作者指南里的同一组数字是现役对照；本表不另造倍率。

## 两轴审查（相对进入本关口的工作树）

固定点：进入本关口时的工作树（不是独立 commit）。审查范围仅本票写入。未派子代理（本会话是实现子代理）。

### Standards

- 无硬违反仓库编码标准。本票文件 `git diff --check` 无 trailing whitespace / space-before-tab / conflict marker。
- 未改 `scripts/`、`managed/safe-tree-delete/policy.json`、hooks、生产 Purge 接线。
- 未新建第三份用户指南。CONTEXT 只留短指针，子票表只在本文。
- 判断：未把设计 Compatibility Matrix 的 4–6x 改成已测；后部设计段仍保留并标「设计预期，不是已测」。
- 判断：未回退 Implementation status 里已删的「snapshot 仍会 dispose lease」句。

### Spec

- 本票是串联父票，不是可直接编码的单一实现。交付是史诗结论，不是新功能。
- 关口必须是 `DONE_WITH_CONCERNS`：生产倍率未达票面 4–6x。已按现役 JSON 写明。
- 生产 Purge 未接 `ParallelPurgeCoordinator`；#40 4.48x 未计入生产倍率。
- 未把本文写成 GitHub 关单授权。最终边仍是 #43 → #26；本票未 close。
- Status / BatchPurge 未做（#49）。

**Standards 0 硬违反 / 2 判断味道；Spec 0 缺失要求，最差是生产倍率未达。**

## 本票文件与 `git diff --check`

- `reports/safe-tree-delete-issue26-20260817/CLOSEABLE.md`
- `docs/specs/2026-08-13-safe-tree-delete-performance-optimization.md`
- `CONTEXT.md`
- `modules/host-safety/CONTEXT.md`
- `modules/manifest.json`（只登记本报告目录前缀）

未改生产热路径、policy、hooks。未接线 `ParallelPurgeCoordinator`。

对照 HEAD 时，性能 spec / CONTEXT / `modules/manifest.json` 的大 diff 含进入本关口前已在工作树的 #32–#43 / #54 WIP（含操作者指南）。本票只做了：Implementation status 末尾史诗指针、`status: landed-below-target`、CONTEXT 短指针、本报告目录前缀。没有把 Implementation status 改回 HEAD 的「Apply/Purge 尚未接入」，也没有写回已删的「snapshot 仍会 dispose lease」。

## 未解决问题

- 生产 Plan→Apply→Purge 未达票面 3x / 4x / 6x。已测生产倍率是 #36 = 1.02x、#42 = 0.962x。
- 生产 Purge 仍走 HostSafety，未接 `ParallelPurgeCoordinator`。夹具 4.48x 不能当删除加速。
- #35 FAT32/网络实卷 e2e 仍是 waiver，未提权验证。
- 同文件后部设计段仍写 4–6x 目标；操作者指南与本文禁止把它读成已上线。
- 工作树原本就脏；本票未回退他人 WIP，未 commit，未 close #26。
