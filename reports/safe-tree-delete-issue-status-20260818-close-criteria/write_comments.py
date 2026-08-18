# -*- coding: utf-8 -*-
from pathlib import Path

DIR = Path(__file__).resolve().parent
FOOTER = (
    "本次只回写关闭条件对照，不 `gh issue close`，不 `gh issue edit` checkbox，"
    "不 commit/push，不 Purge leftover `0ab1e1b6`，不 Archive #48 的 42 条。"
)

comments = {}

comments[18] = f"""## 关闭条件对照（2026-08-18）

**结论：不满足关闭条件。** GitHub 保持 OPEN。

原生 blocked-by 仍是 #21 + #24，二者都还 OPEN。归档、退出码、归因已有证据；日常 Status SLA 已拆到 #49，不挡本票。`complete=false` 是合理终态，不是本票失败。

关票顺序：#22 → #24 → #21 → 本票。#48 / #49 是有意开放的 successor。

{FOOTER}
"""

comments[21] = f"""## 关闭条件对照（2026-08-18）

**结论：未完全满足。** GitHub 保持 OPEN。

已满足：真实 wrapper `leaf-delete-failed` 非零。默认分支证据 `reports/safe-tree-delete-issue55-20260816/leaf-delete-failed.json`（`exitCode=1`）。fixture / suite `ok=true` 不能替代。

未完全满足的是「既有全部测试保持通过」：

- `Test-CodexSafeTreeDeleteFileSystem.ps1` 仍因 diskpart 740 红，应算 #35 waiver，不是 DetectFileSystem 回归。
- 两处意外红已在工作树改测试断言修好，对应文件单测 exit 0；**未再跑完整 27 项**。这正是本票被 reopen 的原因。

若接受「FileSystem = #35 waiver，且不必再跑全量 27」，本票才可关。当前不关。

{FOOTER}
"""

comments[22] = f"""## 关闭条件对照（2026-08-18）

**结论：满足关闭条件。** GitHub 仍保持 OPEN，等用户确认后再 close。

归档已做。AC 允许「降至约 79，实际剩余条数与预期偏差有解释」，不要求 `complete=true`。现役 Status blocking=**116**（#49 三联），含 #48 的 **42** 条 purged+manual-review；不要把票面约 79 当成必须打到的数，也不要 Archive 这 42 条。

blocked-by #19 已 CLOSED。本票可先关，然后才轮到 #24。

{FOOTER}
"""

comments[24] = f"""## 关闭条件对照（2026-08-18）

**结论：自身 AC 已齐，但 GitHub 仍 blocked-by #22，现在不能关。** 保持 OPEN。

归档后 Status 已留存在默认分支证据包。`complete=false` 合理。日常「顺手确认」不满足，已独立立项 #49。只读零写入。生产 smoke 走 #55/#47，已 CLOSED。

回写 #11/#17 是关票动作（#52），尚未发出。等 #22 关闭后再关本票。

{FOOTER}
"""

comments[26] = f"""## 关闭条件对照（2026-08-18）

**结论：不满足关闭条件。** 保持 OPEN。

史诗目标仍是生产 Plan→Apply→Purge **4–6x**。实测 #36=**1.02x**、#42=**0.962x**。生产 Purge 未接 `ParallelPurgeCoordinator`。原生 blocked-by #43，而 #43 又 blocked-by 未达标的 #42。

不要把夹具 DOP4=4.48x 加进生产倍率。Status 属 #49，不在本票。

{FOOTER}
"""

comments[32] = f"""## 关闭条件对照（2026-08-18）

**结论：不满足关闭条件。** 保持 OPEN。

票面要求 10k Apply **1.5–2x**。实测 **0.868x**（349164 / 302992）。缓存已消掉同一 invocation 后两次 SHA-256；墙钟由三次 snapshot/lease 主导。不跳过 identity 去假装加速。

{FOOTER}
"""

comments[33] = f"""## 关闭条件对照（2026-08-18）

**结论：满足关闭条件。** GitHub 仍保持 OPEN，等用户确认后再 close。

功能 AC 已 live 证明。10k 只要**报告**哈希复用收益，没有写死倍率；实测 **0.921x** 已记录。blocked-by #30/#31/#54 均 CLOSED。

{FOOTER}
"""

comments[35] = f"""## 关闭条件对照（2026-08-18）

**结论：满足关闭条件（FAT32/网络实卷维护者 waiver）。** GitHub 仍保持 OPEN，等用户确认后再 close。

Detect / `DeletionAllowed` 已接。本机 C–F 均为 NTFS，无网络卷；一次性 FAT32 VHD 因 diskpart 740 未提权。FileSystem 测试红不改 DetectFileSystem。blocked-by #27 已 CLOSED。

{FOOTER}
"""

comments[36] = f"""## 关闭条件对照（2026-08-18）

**结论：不满足关闭条件。** 保持 OPEN。

票面要求 Phase1 / baseline ≤ 0.33（≥**3x**）。10k×160KiB 实测 **1.02x**，`metTarget=false`。另 blocked-by #32 仍 OPEN。

{FOOTER}
"""

comments[37] = f"""## 关闭条件对照（2026-08-18）

**结论：不满足关闭条件。** 保持 OPEN。

票面要求相对 Phase1 **1.2–1.5x**、相对 baseline **3.5–4x**。10k×4KB 实测 **1.02x / 0.964x**。删除仍走 HostSafety 串行，不是全树 `File.Delete`。另 blocked-by #36 仍 OPEN。

{FOOTER}
"""

comments[39] = f"""## 关闭条件对照（2026-08-18）

**结论：满足关闭条件。** GitHub 仍保持 OPEN，等用户确认后再 close。

票面 AC 全是 Coordinator 类、夹具测试与 10k 正确性，**没有**要求接到生产 `Invoke-CodexSafeTreeDeletePurge`。生产接线属 #42，本票不靠接线才算完成。blocked-by #38 已 CLOSED。

{FOOTER}
"""

comments[40] = f"""## 关闭条件对照（2026-08-18）

**结论：自身基准 AC 已齐，但 GitHub 仍 blocked-by #39，现在不能关。** 保持 OPEN。

夹具 `File.Delete`：DOP4 效率峰值 **4.48x**。这不是生产 Purge 加速，不得加进 #42。新跑写入 `reports/safe-tree-delete-parallelism-benchmark/`，不再覆盖 #40 frozen raw。等 #39 关闭后再关本票。

{FOOTER}
"""

comments[41] = f"""## 关闭条件对照（2026-08-18）

**结论：不满足关闭条件。** 保持 OPEN。

票面要求 10k journal overhead **<10%**。热路径保持 `Flush(true)`（hit disk）时实测 **14.887%**，`IsWithinTarget=false`，`FlushCount=20000`。曾用 `Flush(false)` 到 0.352%，违反 spec，已打回。不靠放宽 hit-disk 关票。

{FOOTER}
"""

comments[42] = f"""## 关闭条件对照（2026-08-18）

**结论：不满足关闭条件。** 保持 OPEN。

票面要求最佳 ≥**6x**、典型 ≥**4x**，以及 journal <10% 与生产并行。生产 Plan→Apply→Purge 实测 **0.962x**，Purge 仍是 HostSafety 串行。夹具 4.48x 未计入生产倍率。另 blocked-by #39/#40/#41 仍 OPEN。

{FOOTER}
"""

comments[43] = f"""## 关闭条件对照（2026-08-18）

**结论：文档 AC 已齐，但 GitHub 仍 blocked-by #42，现在不能关。** 保持 OPEN。

操作者指南已写诚实数字（生产 1.02x / 0.962x，未把 4–6x 写成已上线）。#41 现役 hit-disk overhead 以 **14.887%** 为准。等 #42 关闭（或其数字 AC 被明确 waiver）后再关本票。

{FOOTER}
"""

comments[45] = f"""## 关闭条件对照（2026-08-18）

**结论：不满足关闭条件。** 保持 OPEN。本票最后关。

四个直属子票：#47 CLOSED，#50 CLOSED（`6937642`），#52 OPEN，#53 OPEN。须 4/4 CLOSED 且 `state_reason=completed` 回读后才关本票。#48 / #49 不是本票 child/blocker。

{FOOTER}
"""

comments[48] = f"""## 关闭条件对照（2026-08-18）

**结论：满足关闭条件。** GitHub 仍保持 OPEN，等用户确认后再 close。

观测合同已落地。42 条 purged+manual-review 继续 blocking 是本票成功，不是清理对象。本票不是 #45 子票；关上它不挡 #45。#49 仍 blocked-by 本票，但 #49 自身 SLA 未达，关本票不会让 #49 变成可关。

{FOOTER}
"""

comments[49] = f"""## 关闭条件对照（2026-08-18）

**结论：不满足关闭条件。** 保持 OPEN。

票面要求三次独立冷启动每次墙钟 **<60s**。实测 **142.286 / 141.992 / 145.850s**，`metTarget=false`。认证未跳过，zeroWrite=true，未 Archive 42 条 #48。证据：`reports/safe-tree-delete-issue49-20260817/cold-summary.json`。

{FOOTER}
"""

comments[52] = f"""## 关闭条件对照（2026-08-18）

**结论：不满足关闭条件（关票序列尚未执行）。** 保持 OPEN。

#47 / #50 已 CLOSED，证据包在默认分支 `6937642`。本票 AC 要求按序关闭 #22 → #24 → #21 → #18 并回写 #11/#17 之后才自关。当前这些叶子仍 OPEN，用户尚未确认关票。不关 #45、#48、#49。

{FOOTER}
"""

comments[53] = f"""## 关闭条件对照（2026-08-18）

**结论：不满足关闭条件。** 保持 OPEN。

原生 blocked-by #52 仍 OPEN。origin/main 的 `a2976bc` / `74f08cb` 相对当前 OPEN 集合已过期，不能当成 tracker 已对齐。执行时必须窄提交，禁止夹带 Sub2API、hooks、`policy.json` 或其他 WIP。不由本票代关 #45。

{FOOTER}
"""

for n, body in comments.items():
    path = DIR / f"comment-{n}.md"
    path.write_text(body.lstrip("\n"), encoding="utf-8", newline="\n")
    print(f"wrote {path.name}")

print(f"count={len(comments)}")
