# -*- coding: utf-8 -*-
from pathlib import Path

ROOT = Path(__file__).resolve().parent
FOOTER = (
    "本次只回写状态，不 `gh issue close`，不 commit/push，"
    "不 Purge leftover `0ab1e1b6`。"
)
LEFTOVER = (
    "leftover 仍在：`reports/.codex-safe-delete-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e.quarantine` "
    "与 `D:\\Codex\\.codex\\run-evidence\\safe-tree-delete\\20260816T021845Z-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e\\transaction.json`。"
    "2026-08-17 复读 SHA-256 仍是 `4e73aedc260c43c536ab9df3d3f6d5f73a065a8a17c26d1706998f583a0339d7`。"
    "属 #45/#50 清空集，不是本票打扫对象。"
)

comments = {}

comments[18] = f"""## 状态回写（2026-08-17）

**实现关口：** 子票功能大多已在本机齐；父票 GitHub 关闭仍 BLOCKED。
**GitHub：** 保持 OPEN。

#21 + #24 的本地证据已齐，但 #50 证据包未进默认分支，#52 关票序列未执行。因此 #18 不能关。

现役 #24 Status（2026-08-16T14:23:31Z）：operations=2356，blocking=110，`complete=false`，墙钟 493.768s。#49 不挡本票。

{LEFTOVER}

{FOOTER}
"""

comments[20] = f"""## 状态回写（2026-08-17）

**实现关口：** DONE（2026-08-16 已回写过传递修复）。
**GitHub：** 保持 OPEN。正式关闭仍走 #52，且 #52 仍被 #50 发布挡住。

受管中间层转发 `$LASTEXITCODE`。`leaf-delete-failed` 经完整 `.cmd` 链为非零；缺确认 Archive 仍是 exit 0 + `confirm-archive-required`。

{LEFTOVER}

{FOOTER}
"""

comments[21] = f"""## 状态回写（2026-08-17）

**实现关口：** DONE（本机 live）。
**GitHub：** 保持 OPEN。关票评论必须等 #50 把证据放到默认分支后再由 #52 发出。

**非零主证据只有这一条：** `reports/safe-tree-delete-issue55-20260816/leaf-delete-failed.json`（`exitCode=1`，`purged=false`，`refusalReason=leaf-delete-failed`，经 live `.cmd`）。

不能用 fixture、套件 `ok=true`、或 `revert-forwarding.json`（`exitCode=0`，负向：wrapper 吞掉非零）冒充这条证明。

{LEFTOVER}

{FOOTER}
"""

comments[22] = f"""## 状态回写（2026-08-17）

**实现关口：** DONE。
**GitHub：** 保持 OPEN。关闭须引用 #24 现役计数，并由 #52 按序执行。

合格 terminal 已退出 `blockingRecords`。现役 live 计数以 #24 为准：operations=**2356**，blocking=**110**（2026-08-16T14:23:31Z）。不要用 02:17 的 2323，也不要把票面「约 79」当成现役目标。

`complete=false` 不是本票失败。110 = 51 plan-only + 1 missing-plan + 42 条 #48 purged+manual-review + 10 planned-namespace + 5 v1 + 1 历史 v2。

{LEFTOVER}

{FOOTER}
"""

comments[23] = f"""## 状态回写（2026-08-17）

**实现关口：** DONE（只读调查，无新代码）。
**GitHub：** 保持 OPEN。关闭走 #52。

票面「69 条 schema+status 均为 null」不是对照快照事实。02:17 与之后的 #24 live 都是 **52** 条 both-null，且全部没有 `transaction.json`（过期计划或有意残缺），不是解析器读不出来。

这 52 条保留原状，不是 Archive 对象。解析器缺口那批（allowlist 拒绝但已有 v2 `purged` 事务）已由 #48 观测出来，必须继续 blocking，不要为本票 Archive。`acl-capability-probe-20260801` 保留，不删除。

现役计数以 #24 为准（2356 / 110）。

{FOOTER}
"""

comments[24] = f"""## 状态回写（2026-08-17）

**实现关口：** DONE（本机 live Status）。
**GitHub：** 保持 OPEN。关闭走 #52，且须先有 #50 默认分支回读。

判定 Status：`capturedAtUtc=2026-08-16T14:23:31Z`，exit 0，墙钟 **493.768s**。operations=**2356**，blocking=**110**，`complete=false`，`migrationReadiness.ready=false`。utf8 SHA `3dc6070797d4b99403d0e91ab96c97841d6c6a4bcf3f69ffe48199cbdfc94efe`。

分解：`2356 = 2244 + 87 + 23 + 1 + 1`；`110 = 51+1+42+10+5+1`。leftover `0ab1e1b6` 可识别为 v2 `purging` / `purge-resumable`，**不在** blocking。

493.768s 不满足「日常顺手确认」。Status 冷启动属 **#49**，#26–#43 不覆盖。只读路径零写入。

{LEFTOVER}

{FOOTER}
"""

comments[26] = f"""## 状态回写（2026-08-17）

**实现关口：** `DONE_WITH_CONCERNS`
**GitHub：** 保持 OPEN。这不是关单。

17 张子票加 #54 的实现关口已齐。生产 Plan→Apply→Purge **未达**票面 4–6x：

- #36：10k×160KiB，527846 / 517444 = **1.02x**
- #42：10k×4KB，513510 / 534034 = **0.962x**

生产 Purge **未接** `ParallelPurgeCoordinator`，仍走 HostSafety 串行删除。#40 夹具 DOP4=4.48x 是 `File.Delete` 墙钟，不是删除加速。

性能 spec `status: landed-below-target`。子票表：`reports/safe-tree-delete-issue26-20260817/CLOSEABLE.md`。操作者指南在 `docs/specs/2026-08-13-safe-tree-delete-performance-optimization.md`。Status / BatchPurge 属 #49，不在本票。

实现仍在工作树，未进默认分支。

{FOOTER}
"""

comments[32] = f"""## 状态回写（2026-08-17）

**实现关口：** `DONE_WITH_CONCERNS`
**GitHub：** 保持 OPEN。

Apply 已接 invocation-local `SessionHashCache` + `GetHashSafely`。#42 之后，snapshot 有 provider 时不再先放 lease，有 lease 时从同一 handle 算哈希。

10k×4KB Apply：reuse 349164ms / baseline 302992ms = **0.868x**，未达 1.5–2x。`reports/safe-tree-delete-issue32-20260817/scale-10000.json`。

未进默认分支。未关票。

{FOOTER}
"""

comments[33] = f"""## 状态回写（2026-08-17）

**实现关口：** `DONE_WITH_CONCERNS`
**GitHub：** 保持 OPEN。

Purge 已接 invocation-local `SessionHashCache`。#42 之后，批量校验 cache hit 只核 identity，不再 `GetHashSafely` 独占重开。

10k×4KB Purge：reuse 224320ms / baseline 206496ms = **0.921x**，未加速。`reports/safe-tree-delete-issue33-20260817/scale-10000.json`。

生产 Purge 仍走 HostSafety，未接 coordinator。未进默认分支。

{FOOTER}
"""

comments[34] = f"""## 状态回写（2026-08-17）

**实现关口：** DONE
**GitHub：** 保持 OPEN。

尚未 `commit-authorized` 的 freeze 按路径是否仍在分为 `pendingFiles` / `uncertainFiles`。uncertain 不得收成 `purged`，Status 为 `manual-review`。CrashSafety 仍绿。

处理建议见能力 spec pending / uncertain 段：手工核验后重新 Plan，或保持 `manual-review`。不要 Purge leftover。

未进默认分支。

{FOOTER}
"""

comments[35] = f"""## 状态回写（2026-08-17）

**实现关口：** waiver（维护者已接受）
**GitHub：** 保持 OPEN。关票仍要另授 close。

FAT32 / 网络实卷 e2e 未提权验证。现役探测：FAT32/exFAT 强制无 `FILE_ID_INFO`，`DeletionAllowed=false`，新 Plan 失败关闭。`RecommendParallel=false` 只约束夹具 coordinator；生产 Purge 本来就是串行。

FileSystem 测试未提权会因 diskpart 740 红，这是已知 waiver，不是本波新回归。

{FOOTER}
"""

comments[36] = f"""## 状态回写（2026-08-17）

**实现关口：** `DONE_WITH_CONCERNS`
**GitHub：** 保持 OPEN。

完整生产 Plan→Apply→Purge，10k×160KiB（每树 1.526 GiB）：baseline 527846ms / Phase1 517444ms = **1.02x**，未达 3x。`metTarget=false`。

`reports/safe-tree-delete-issue36-20260817/scale-phase1.json`。夹具树已清。未进默认分支。

{FOOTER}
"""

comments[37] = f"""## 状态回写（2026-08-17）

**实现关口：** `DONE_WITH_CONCERNS`
**GitHub：** 保持 OPEN。

Purge 先收集 `List<PurgeFileLeaf>` 再验证；删除仍走 HostSafety 逐 leaf freeze/commit。一度尝试的 HostSafety collect-then-process 已撤回。

10k×4KB：batch 187157 / Phase1 190905 / baseline 180384ms = **1.02x** / **0.964x**。该墙钟测于撤回前，未重跑。

`reports/safe-tree-delete-issue37-20260817/scale-10000.json`。未进默认分支。

{FOOTER}
"""

comments[38] = f"""## 状态回写（2026-08-17）

**实现关口：** DONE
**GitHub：** 保持 OPEN。

`ThreadJournalWriter` / `ThreadJournalOwner` 已落地（ThreadLocal 生命周期与单元测试）。**未接**生产 Purge 热路径。

`reports/safe-tree-delete-issue38-20260817/CLOSEABLE.md`。未进默认分支。

{FOOTER}
"""

comments[39] = f"""## 状态回写（2026-08-17）

**实现关口：** `DONE_WITH_CONCERNS`
**GitHub：** 保持 OPEN。

`ParallelPurgeCoordinator` 已落地：目录级 `Parallel.ForEach` + 每线程 journal，夹具树 `File.Delete`。10k 小文件 31339ms / 4 journal / 0 失败。

**生产 `Invoke-CodexSafeTreeDeletePurge` 未接线。** 夹具墙钟不是删除加速。

`reports/safe-tree-delete-issue39-20260817/CLOSEABLE.md`。未进默认分支。

{FOOTER}
"""

comments[40] = f"""## 状态回写（2026-08-17）

**实现关口：** `DONE_WITH_CONCERNS`
**GitHub：** 保持 OPEN。

夹具 `File.Delete` 基准（不是生产 Purge）：10k×1KB DOP4=13255ms / DOP1=59439ms = **4.48x**（效率峰值）；DOP2=2.17x；墙钟最快 DOP16=4926ms。`FromDetection` optimize 仍为 4。

这些数字**不得**加进 #42 生产倍率。生产 Purge 未接 coordinator。

`reports/safe-tree-delete-issue40-20260817/analysis.json`。未进默认分支。

{FOOTER}
"""

comments[41] = f"""## 状态回写（2026-08-17）

**实现关口：** `DONE_WITH_CONCERNS`
**GitHub：** 保持 OPEN。

夹具 10k journal flush：TotalFlushTimeMs 6144 / elapsed 32927ms = overhead **18.659%**，`IsWithinTarget=false`（目标 <10%）。公式是线程求和，不是墙钟伪装。

生产 HostSafety journal 是串行 create-only，没有这条 flush 占比合同。

`reports/safe-tree-delete-issue41-20260817/scale-10000.json`。未进默认分支。

{FOOTER}
"""

comments[42] = f"""## 状态回写（2026-08-17）

**实现关口：** `DONE_WITH_CONCERNS`
**GitHub：** 保持 OPEN。

Apply 双开阻塞已解：snapshot 有 provider 时不再先放 lease；Apply/Purge 有 lease 时从同一 handle 算哈希。未放宽 `FileShare.None`，未接 coordinator。

生产路径 10k×4KB Plan→Apply→Purge：baseline 513510ms / phase3-prod 534034ms = **0.962x**，`metTargetBest=false`，`metTargetTypical=false`。未达 4x/6x。#40 夹具 4.48x **未计入**本票。

`reports/safe-tree-delete-issue42-20260817/scale-phase3.json`。{LEFTOVER}

未进默认分支。

{FOOTER}
"""

comments[43] = f"""## 状态回写（2026-08-17）

**实现关口：** `DONE_WITH_CONCERNS`
**GitHub：** 保持 OPEN。

票面 16 条 AC 已落到现役性能 spec「操作者指南」：三阶段落地、FILE_ID_INFO、哈希复用、并行仅夹具、两层实测表、故障排查、必须重 Plan、API 现役契约。未另造第三份用户指南。

生产表写已测 **1.02x / 0.962x**，并写明未达票面 4x/6x。夹具 4.48x 单独成表。同文件后部设计段仍有 4–6x 目标语，已标明不是已测。

`reports/safe-tree-delete-issue43-20260817/CLOSEABLE.md`。未进默认分支。

{FOOTER}
"""

comments[44] = f"""## 状态回写（2026-08-17）

**实现关口：** DONE（本机测试）。
**GitHub：** 保持 OPEN。实现在工作树，未 commit。

`tests/Test-CodexSerenaBehaviorHooks.ps1` exit 0。guard pin SHA-256 `85d78b8533a47f8a9f3419e1bc4db33e3351522d7e8c1fe1aa861c0399f4ea3a`，与两份 manifest 一致。

未改 `managed/safe-tree-delete/policy.json`、safe-delete 生产 lib。关票还要提交 hooks + 结论评论 + close 授权。

`reports/serena-issue44-20260817/CLOSEABLE.md`。

{FOOTER}
"""

comments[45] = f"""## 状态回写（2026-08-17）

**实现关口：** DAG 只读核验 DONE。
**GitHub 关闭：** 不可关。须等四个直属子票 #47 / #50 / #52 / #53 全部 `CLOSED` 且 `state_reason=completed`。

计划 blocked-by **35/35**、parent **12/12** 均为原生匹配。#49 不是本票 child/blocker。票面 checkbox 仍是 `[ ]`（未 `gh edit`）。

四子票仍 OPEN。#50 未发布到默认分支，#52 关票序列未执行。

{LEFTOVER}

{FOOTER}
"""

comments[46] = f"""## 状态回写（2026-08-17）

**实现关口：** DONE（Reminder AC 本机绿）。
**GitHub：** 保持 OPEN。未 commit。

同 session 命名互斥 + Reminder 250ms fail-open 已在工作树。Activation 在同 session 锁被占用时不拿锁的锚点已补。套件 exit 0。pin 仍是 `85d78b85…`。

`reports/serena-issue46-20260817/CLOSEABLE.md`。关票还要提交 + close 授权。

{FOOTER}
"""

comments[47] = f"""## 状态回写（2026-08-17）

**实现关口：** 本机对照可关。
**GitHub 关闭：** BLOCKED on #50 publish。

入口 / wrapper / 仓库源 identity 一致。非零主证据：`reports/safe-tree-delete-issue55-20260816/leaf-delete-failed.json` `exitCode=1`。`revert-forwarding.json` 是 exit 0，不能当非零主证据。

未满足的 AC 是「closure-grade 证据进入远端默认可读的版本化位置」。证据仍在本机 `reports/`。

{LEFTOVER}

{FOOTER}
"""

comments[48] = f"""## 状态回写（2026-08-17）

**实现关口：** DONE（2026-08-16 已回写过观测合同）。
**GitHub：** 保持 OPEN。本票有意不在 #45 关票序列里关闭。

plan 被当前 policy 拒绝后，Status 仍只读观测历史事务。生产里 42 条 `purged` + `lifecycle=manual-review` **是观测成功**，必须继续计入 blocking。不要为本票去清 blocking 或 Archive 这 42 条。

现役 #24：blocking=110，其中这 42 条仍在。未改 Status 实现。

{FOOTER}
"""

comments[49] = f"""## 状态回写（2026-08-17）

**实现关口：** 未开始。
**GitHub：** 保持 OPEN。

本票独立于 #26–#43，也不挡 #45。#26 史诗已收口且明确排除 Status / BatchPurge。

最近一次生产 Status（#24，2026-08-16T14:23:31Z）墙钟 **493.768s**，operations=2356。票面要求 3 次独立冷启动每次 <60s，目前未建冷/热测量协议，也未做三次冷启动。

不要把 Apply/Purge 的 invocation-local 哈希复用误报为本票已优化。不要用跳过 terminal-archive 认证换速度。

{FOOTER}
"""

comments[50] = f"""## 状态回写（2026-08-17）

**实现关口：** 工作区清单齐。
**GitHub 关闭 / 默认分支回读：** 未做。未 `git add` / commit / push。

将来一次 `git add` 的精确相对路径见 `reports/safe-tree-delete-issue50-20260816/STAGED-FILE-LIST.txt`（**238** 个文件；清单文件含 4 行注释）。`verify-issue50-pack.py` 当时 exit 0。

包内含 #55 smoke、#24 Status、#21/#47 对照所需相对路径。不含 leftover quarantine、`policy.json`、`CodexSafeTreeDelete.ps1`、Serena #44 WIP。

{LEFTOVER}

{FOOTER}
"""

comments[51] = f"""## 状态回写（2026-08-17）

**实现关口：** DONE（Cleanup 真超时本机绿）。
**GitHub：** 保持 OPEN。未 commit。

Cleanup 有界等待：真超时 ≥6000ms 仍空返回，且不改写 session 文件。套件 `Test-CodexSerenaBehaviorHooks.ps1` exit 0。pin 仍是 `85d78b85…`。

`reports/serena-issue51-20260817/CLOSEABLE.md`。关票还要提交 + close 授权。

{FOOTER}
"""

comments[52] = f"""## 状态回写（2026-08-17）

**实现关口：** 评论草稿已在本机写好。
**GitHub：** 关票序列 **未执行**。本次回写不是本票规定的「先评论后 close」。

草稿：`reports/safe-tree-delete-issue52-20260817/`。预定顺序 `#19→#22→#23→#24`，`#20→#21`，`#21+#24→#18`。#21 只引 `leaf-delete-failed.json` exit 1。不关 #45。

挡住执行的条件仍在：#50 未把证据包提交并推到默认分支；也还没有 close 授权。本波只把各票**现状**写回评论。

{FOOTER}
"""

comments[53] = f"""## 状态回写（2026-08-17）

**实现关口：** 未到执行窗口。
**GitHub：** 保持 OPEN。

本票要在 #52 按序关闭 #20–#24 与 #18 之后，同步 tracker 真源并自关闭。#45 由父流程最后关。

当前 #52 未执行，#50 未发布，四子票仍 OPEN。不要提前改票面 checkbox 或 close #45。

{FOOTER}
"""

comments[54] = f"""## 状态回写（2026-08-17）

**实现关口：** DONE（2026-08-16 已回写过功能验收）。
**GitHub：** 保持 OPEN。15 条缺 `leafStreamSetV1` 的在途是部署前 / #45/#50 清空门禁，不是本票功能缺口。

Plan 写 `leafStreamSetV1`；Apply/Purge 在各自 live freeze 消费并发布 `leaf-dispositions.json`。缺节旧 Plan 在 Apply/Purge 失败闭锁；Status/Archive 只读不受影响。

未 Restore/Purge 任何时钟倒计时路径，也未清 leftover。

{LEFTOVER}

{FOOTER}
"""

comments[55] = f"""## 状态回写（2026-08-17）

**实现关口：** DONE（本机 live smoke）。
**GitHub：** 保持 OPEN。证据未进默认分支。

`tests/Test-CodexSafeTreeDeleteProductionSmoke.ps1` 经 live wrapper：`summary.json` exit 0，`wallClockSeconds=407.492`，`invocationCount=20`。Status 代际绑定用 `operations[].operationId`。

非零主证据：`leaf-delete-failed.json` `exitCode=1`。缺确认 Archive 仍是 exit 0 + `confirm-archive-required`。超时是 harness 合同，未给 wrapper 加 timeout 参数。

计数、哈希、退出码以该目录 JSON 为准，不要用过期 Markdown 墙钟。

{LEFTOVER}

{FOOTER}
"""

for number, body in comments.items():
    path = ROOT / f"comment-{number}.md"
    path.write_text(body.rstrip() + "\n", encoding="utf-8")
    print(f"wrote {path.name} ({len(body)} chars)")

print(f"total={len(comments)}")
