# -*- coding: utf-8 -*-
from pathlib import Path

DIR = Path(__file__).resolve().parent
FOOTER = (
    "本次只回写状态，不 `gh issue close`，不 `gh issue edit` checkbox，"
    "不 commit/push，不 Purge leftover `0ab1e1b6`，不 Archive #48 的 42 条 purged+manual-review。"
)
LEFTOVER = (
    "leftover 仍在：`reports/.codex-safe-delete-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e.quarantine` "
    "与 `D:\\Codex\\.codex\\run-evidence\\safe-tree-delete\\"
    "20260816T021845Z-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e\\transaction.json`。"
    "最近 Status 三联 SHA-256 仍是 "
    "`4e73aedc260c43c536ab9df3d3f6d5f73a065a8a17c26d1706998f583a0339d7`，"
    "lifecycle=`purge-resumable`，不在 blocking。属 #45 清空集，不是本票打扫对象。"
)

comments = {}

comments[18] = f"""## 状态回写（2026-08-18）

**实现关口：** 子票证据大多已齐；父票 GitHub 关闭仍等用户确认。
**GitHub：** 保持 OPEN。

#20 / #23 仍 CLOSED。#21 / #22 / #24 仍 OPEN，所以本票不能关。#50 证据包已在默认分支 `6937642`；#47 / #50 CLOSED。#52 / #53 仍 OPEN。

#21 wrapper 非零证据仍以 `reports/safe-tree-delete-issue55-20260816/leaf-delete-failed.json`（`exitCode=1`）为准。fixture 全量 27 项曾记 24 绿 / 3 红；两处意外红已在工作树用测试断言修好（生产未改），FileSystem 红仍是 #35 diskpart 740 waiver。ProductionSmoke 未重跑。

最近 live Status（#49 三联，约 2026-08-18T02:09+08）：operations=**2482**，blocking=**116**，`complete=false`，墙钟约 **142s**。#49 SLA 未达，不挡本票关闭条件里的独立 successor 关系。

{LEFTOVER}

{FOOTER}
"""

comments[21] = f"""## 状态回写（2026-08-18）

**实现关口：** 非零 wrapper 证据 DONE（默认分支）；fixture 全量 AC **部分**。
**GitHub：** 保持 OPEN。

**非零主证据只有这一条（origin/main）：** `reports/safe-tree-delete-issue55-20260816/leaf-delete-failed.json`（`exitCode=1`，`purged=false`，`refusalReason=leaf-delete-failed`，经 live `.cmd`）。fixture / suite `ok=true` 不能替代。

fixture 全量（`reports/safe-tree-delete-issue21-regression-20260818/summary.json`）：27/27 都有 exit；**24 绿 / 3 红**；leftover SHA 前后不变。

| 测试 | 归类 | 现状 |
| --- | --- | --- |
| `Test-CodexSafeTreeDeleteFileSystem.ps1` | #35 waiver | diskpart Win32 740，未提权；不改 DetectFileSystem |
| `Test-CodexSafeTreeDelete.ps1` | 意外红，已修测试 | 现役原因是 `IdentityMismatch`；工作树断言改为 `IdentityMismatch\\|漂移`；该文件复跑 exit **0**。未改生产 |
| `Test-CodexSafeTreeDeletePhase3Integration.ps1` | 意外红，已修测试 | 不再钉 #40 `wallClockMs==13255`；只核存在/fileCount/degree/`wallClockMs>0`。该文件复跑 exit **0**。Benchmark 新跑写入 `reports/safe-tree-delete-parallelism-benchmark/`，不再覆盖 #40 raw |

未再跑完整 27 项，未跑 ProductionSmoke。测试修复仍在工作树，未进默认分支。

{LEFTOVER}

{FOOTER}
"""

comments[22] = f"""## 状态回写（2026-08-18）

**实现关口：** 归档能力 DONE。
**GitHub：** 保持 OPEN。关闭须引用现役 Status 计数，并由用户确认后走 #52。

合格 terminal 已退出 `blockingRecords`。不要把票面「约 79」当成现役目标，也不要求 `complete=true`。

最近 live Status（#49 三联）：operations=**2482**，blocking=**116**，`complete=false`，purged+manual-review 仍为 **42**。这 42 条是 #48 观测成功，必须继续 blocking；不要 Archive 它们来换 #49 时间。

对照 2026-08-16 #24 快照曾是 operations=2356 / blocking=110。现场记录变多，以最近 Status JSON 为准。

{LEFTOVER}

{FOOTER}
"""

comments[24] = f"""## 状态回写（2026-08-18）

**实现关口：** 归档后 Status 已留存；日常 SLA 在 #49，**未达**。
**GitHub：** 保持 OPEN。

2026-08-16 判定快照仍有效作归档后基线：exit 0，墙钟 **493.768s**，当时 operations=2356 / blocking=110 / `complete=false`。`complete=false` 合理。

之后 #49 做了 Status 解析优化并重测三次冷启动（live `.cmd`，pwsh 7.6.4）：墙钟 **142.286 / 141.992 / 145.850s**，`metTarget=false`。现役计数 operations=**2482**，blocking=**116**，#48 MR=**42**，zeroWrite=**true**。证据：`reports/safe-tree-delete-issue49-20260817/cold-summary.json`。

Status 冷启动不属 #26–#43。未用 VSS，未跳过 terminal-archive 认证。

{LEFTOVER}

{FOOTER}
"""

comments[26] = f"""## 状态回写（2026-08-18）

**实现关口：** `DONE_WITH_CONCERNS`
**GitHub：** 保持 OPEN。数字 AC 未满足的子票仍 OPEN。

库、Plan 采集、Apply/Purge 会话哈希复用、uncertain、批量验证、夹具 coordinator / journal 监控、操作者指南都已在工作树落地。生产 Plan→Apply→Purge **未达**票面 4–6x：

- #36：10k×160KiB，**1.02x**，`metTarget=false`
- #42：10k×4KB，**0.962x**，`metTarget=false`

生产 Purge **未接** `ParallelPurgeCoordinator`，仍走 HostSafety 串行删除。#40 夹具 DOP4=4.48x 是 `File.Delete` 墙钟，不是生产加速。

子票关口：#32 / #41 **BLOCKED**（数字不可达且不放宽安全合同）；#33 / #35 / #39 / #40 / #43 功能或文档关口已齐但未关 GitHub；#36 / #37 / #42 倍率未达。Status / BatchPurge 属 #49，不在本票。

实现仍在工作树，未把性能 DAG 整包推进默认分支。

{FOOTER}
"""

comments[32] = f"""## 状态回写（2026-08-18）

**实现关口：** `BLOCKED`
**GitHub：** 保持 OPEN。数字 AC 1.5–2x **未达**，不伪造加速。

功能：Apply 读 Plan `fileIdentitiesV2`，invocation-local `SessionHashCache`。同一 invocation 对每个 `FileIdentityV2` 内容哈希三次（unlocked / locked / quarantine postcheck）；缓存已消掉后两次 SHA-256。

10k 互异 4KB：复用 349164ms / 基线 302992ms = **0.868x**，`metTarget=false`。墙钟由三次整树 snapshot / lease 主导，不是 SHA-256。不跳过 identity，不跳过 snapshot。

`reports/safe-tree-delete-issue32-20260817/summary.json`。HashReuse / HashSafely / Status 测试 exit 0。未改 Status/#49 hunk。未进默认分支。

{FOOTER}
"""

comments[33] = f"""## 状态回写（2026-08-18）

**实现关口：** `DONE_WITH_CONCERNS`
**GitHub：** 保持 OPEN。关票仍要另授 close。

功能 AC 已 live 证明：Purge 消费 Plan `fileIdentitiesV2` 与 leaf stream-set；每个 invocation 自建空 `SessionHashCache`；IdentityMismatch / stream-set 漂移拒绝且不删除。1000 文件 Plan→Apply→Purge 成功。

10k×4KB：**0.921x**（224320 / 206496），未加速，如实记录。未扩到 Status / CLI BatchPurge。

`reports/safe-tree-delete-issue33-20260817/CLOSEABLE.md`。未进默认分支。

{FOOTER}
"""

comments[35] = f"""## 状态回写（2026-08-18）

**实现关口：** waiver（维护者已接受）
**GitHub：** 保持 OPEN。关票仍要另授 close。

Detect / `DeletionAllowed` 已接。FAT32 / 网络实卷 e2e 未提权验证。现役：FAT32/exFAT 强制无 `FILE_ID_INFO`，`DeletionAllowed=false`，新 Plan 失败关闭。

#21 fixture 全量里 `Test-CodexSafeTreeDeleteFileSystem.ps1` 仍因 diskpart Win32 740 红。这是本票 waiver，不是 DetectFileSystem 回归，不改生产探测去「修绿」。

{FOOTER}
"""

comments[36] = f"""## 状态回写（2026-08-18）

**实现关口：** `DONE_WITH_CONCERNS`
**GitHub：** 保持 OPEN。3x **未达**。

10k×160KiB 两棵兄弟树完整 Plan→Apply→Purge：baseline 527846ms / Phase1 517444ms = **1.02x**，`metTarget=false`。安全路径 IdentityMismatch 仍拒绝。本机 NTFS；FAT32 / 网络未验证（#35 waiver）。

`reports/safe-tree-delete-issue36-20260817/CLOSEABLE.md`。未进默认分支。不要把 3x 读成已上线。

{FOOTER}
"""

comments[37] = f"""## 状态回写（2026-08-18）

**实现关口：** `DONE_WITH_CONCERNS`
**GitHub：** 保持 OPEN。1.2–1.5x / 3.5–4x **未达**。

Purge 先收集 file leaf 再校验，删除仍走 HostSafety freeze / handle-bound。没有全树 pending 再全树 `File.Delete`。

10k×4KB：相对 Phase1 **1.02x**，相对无复用 baseline **0.964x**。CrashSafety / Uncertain / LeafStreamSet 仍绿。未碰 leftover。

`reports/safe-tree-delete-issue37-20260817/CLOSEABLE.md`。未进默认分支。

{FOOTER}
"""

comments[39] = f"""## 状态回写（2026-08-18）

**实现关口：** `DONE_WITH_CONCERNS`
**GitHub：** 保持 OPEN。

`ParallelPurgeCoordinator` 夹具 AC 通过（真类型、真 `Parallel.ForEach`、真 journal）。`File.Delete` 只打 issue39 夹具树。现役 `Invoke-CodexSafeTreeDeletePurge` **未接线**，仍走 `Remove-CodexHookCapabilityDirectoryTree`。

不要为 #36/#42 倍率去把 coordinator 接进生产 Purge。

`reports/safe-tree-delete-issue39-20260817/CLOSEABLE.md`。未进默认分支。

{FOOTER}
"""

comments[40] = f"""## 状态回写（2026-08-18）

**实现关口：** `DONE_WITH_CONCERNS`
**GitHub：** 保持 OPEN。

夹具 `File.Delete` 基准（不是生产 Purge）：10k×1KB DOP4=13255ms / DOP1=59439ms = **4.48x**（效率峰值）；DOP2=2.17x。`FromDetection` optimize 仍为 4。这些数字不得加进 #42 生产倍率。

#21 回归曾覆盖 `reports/safe-tree-delete-issue40-20260817/raw/`。之后 ParallelismBenchmark 改为写入 `reports/safe-tree-delete-parallelism-benchmark/`；对 frozen #40 raw 做 SHA 守卫。Phase3 不再钉历史 `wallClockMs==13255`。

未进默认分支。生产 Purge 未接 coordinator。

{FOOTER}
"""

comments[41] = f"""## 状态回写（2026-08-18）

**实现关口：** `BLOCKED`
**GitHub：** 保持 OPEN。`<10%` overhead **未达**，且不靠放宽 hit-disk 假装达标。

监控、公式、报告、慢 flush 警告和 10k 夹具都在。热路径已恢复 `FileStream.Flush(true)`。#39 每文件 `pending→Flush→Delete→commit→Flush` 未改成批量 fsync。生产 Purge 未接线。

曾用 `Flush(false)` 量到 0.352%，违反「Pending entry must hit disk before OS delete」，已打回。

现役 10k（hit-disk）：`TotalFlushTimeMs=9030` / `elapsedMs=60656` = **14.887%**，`IsWithinTarget=false`，`FlushCount=20000`。删除仍成功，未失败闭锁。

`reports/safe-tree-delete-issue41-20260817/suite-meta.json`。未进默认分支。

{FOOTER}
"""

comments[42] = f"""## 状态回写（2026-08-18）

**实现关口：** `DONE_WITH_CONCERNS`
**GitHub：** 保持 OPEN。生产 4x / 6x **未达**。

生产路径 10k×4KB Plan→Apply→Purge：534034 / 513510 = **0.962x**，`metTargetBest=false` / `metTargetTypical=false`。生产 Purge 仍是 HostSafety 串行。

Coordinator 夹具 DOP4=4.48x **未计入**生产倍率。未放宽 `FileShare.None`，未接 `ParallelPurgeCoordinator` 到生产。

`reports/safe-tree-delete-issue42-20260817/CLOSEABLE.md`。未进默认分支。

{FOOTER}
"""

comments[43] = f"""## 状态回写（2026-08-18）

**实现关口：** `DONE_WITH_CONCERNS`
**GitHub：** 保持 OPEN。关票仍要另授 close。

票面文档 AC 已落到性能 spec「操作者指南」：三阶段落地、FILE_ID_INFO、哈希复用、并行仅夹具、两层实测表。生产表写已测 **1.02x / 0.962x**，写明未达票面 4x/6x。夹具 4.48x 单独成表。

#41 现役 hit-disk overhead 是 **14.887%**（`Flush(true)` 打回后）。若指南里仍出现较早的 18.659% / 0.352%，以 #41 `suite-meta.json` 为准，不要把 `<10%` 写成已上线。

`reports/safe-tree-delete-issue43-20260817/CLOSEABLE.md`。文档改动仍在工作树。

{FOOTER}
"""

comments[45] = f"""## 状态回写（2026-08-18）

**GitHub 关闭：** 不可关。须等四个直属子票 #47 / #50 / #52 / #53 全部 `CLOSED` 且 `state_reason=completed`。本票最后关。

当前：#47 CLOSED，#50 CLOSED（证据包在默认分支 `6937642`），#52 OPEN，#53 OPEN。

#21 / #22 / #24 / #18 仍 OPEN；用户尚未确认关票序列。#48 / #49 不是本票 child/blocker，保持独立 OPEN。

{LEFTOVER}

{FOOTER}
"""

comments[48] = f"""## 状态回写（2026-08-18）

**实现关口：** DONE（观测合同仍成立）。
**GitHub：** 保持 OPEN。本票有意不在 #45 关票序列里关闭。

plan 被当前 policy 拒绝后，Status 仍只读观测历史事务。生产里 **42** 条 `purged` + `lifecycle=manual-review` 是观测成功，必须继续计入 blocking。

#49 三次冷启动仍报告 `purgedManualReviewCount=42`。不要 Archive 这 42 条来换 Status 墙钟。`tests/Test-CodexSafeTreeDeleteStatus.ps1` slices=22。相关 Status 优化在工作树，未进默认分支。

{FOOTER}
"""

comments[49] = f"""## 状态回写（2026-08-18）

**实现关口：** `DONE_WITH_CONCERNS`。票面三次冷启动 **<60s 未达**。
**GitHub：** 保持 OPEN。

入口：`D:\\Codex\\.codex\\scripts\\invoke-safe-tree-delete.cmd -Mode Status -Json`。pwsh 7.6.4。证据：`reports/safe-tree-delete-issue49-20260817/cold-summary.json`。

| 次 | 墙钟 s | elapsedMs | operations | entriesScanned | bytesHashed | zeroWrite | #48 MR |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 142.286 | 139627 | 2482 | 3952 | 912539936 | true | 42 |
| 2 | 141.992 | 139162 | 2482 | 3952 | 912539936 | true | 42 |
| 3 | 145.850 | 142979 | 2482 | 3952 | 912539936 | true | 42 |

`allUnder60s=false`，`metTarget=false`。认证未跳过。未消费 Apply/Purge `SessionHashCache`。并行 `ConvertFrom-Json` 未落地（子 runspace 会更慢）。成本仍在 activeResolve ~86s + archivedResolve ~48s。

对照优化前（2026-08-17）约 189/184/182s。现场 operations 现为 2482。未改 `policy.json`。实现仍在工作树。

{LEFTOVER}

{FOOTER}
"""

comments[52] = f"""## 状态回写（2026-08-18）

**实现关口：** 关票序列 **未执行**。本次不是本票规定的「先结论评论后 close」。
**GitHub：** 保持 OPEN。

#50 证据包已在默认分支 `6937642`。#47 CLOSED。仍挡住执行的是：#21 / #22 / #24 / #18 仍 OPEN，且用户尚未确认关票。

预定顺序仍是 `#22` → 跳过已 CLOSED 的 `#23` → `#24` → `#21` → `#18`，然后才轮到本票回写并关闭那些票。不关 #45。不关 #48 / #49。

#21 只引 `leaf-delete-failed.json` exit 1。不要用 fixture 绿冒充 wrapper 非零。

{FOOTER}
"""

comments[53] = f"""## 状态回写（2026-08-18）

**实现关口：** 未到执行窗口。
**GitHub：** 保持 OPEN。

本票要在 #52 按序关闭 #20–#24 与 #18 之后，同步 tracker 真源并自关闭。#45 由父流程最后关。

origin/main 已有 `a2976bc` / `74f08cb` tracker 文档提交，但控制面票随后 REOPENED，那些提交相对 **当前 OPEN 集合已过期**。不要把它们读成「tracker 已与 live 对齐」。

执行本票时必须 **窄提交**：只同步 tracker 真源。禁止夹带 Sub2API、grok-hooks、`policy.json`、leftover quarantine、未关票的性能 WIP。

{FOOTER}
"""

for n, body in comments.items():
    path = DIR / f"comment-{n}.md"
    path.write_text(body.lstrip("\n"), encoding="utf-8", newline="\n")
    print(f"wrote {path.name} chars={len(body)}")

print(f"count={len(comments)}")
