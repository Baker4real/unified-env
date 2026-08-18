# -*- coding: utf-8 -*-
from pathlib import Path

ROOT = Path(__file__).resolve().parent
FOOTER = (
    "本次只回写状态，不 `gh issue close`，不 commit/push，"
    "不 Purge leftover `0ab1e1b6`，不执行 #52 关票序列。"
)
LEFTOVER = (
    "leftover 仍在：`reports/.codex-safe-delete-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e.quarantine` "
    "与 `D:\\Codex\\.codex\\run-evidence\\safe-tree-delete\\20260816T021845Z-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e\\transaction.json`。"
    "SHA-256 仍是 `4e73aedc260c43c536ab9df3d3f6d5f73a065a8a17c26d1706998f583a0339d7`。"
    "属 #45 清空集，不是本票打扫对象。"
)
PACK = (
    "控制面证据包已在默认分支 `6937642`："
    "https://github.com/Baker4real/unified-env/commit/6937642be268a9e7d70b9c7162a576c5d942beaa"
)
CLOSED_PRE = "#54 / #55 / #50 / #47 已 CLOSED（completed）。"

comments = {}

comments[18] = f"""## 状态回写（2026-08-17 续）

**实现关口：** 子票功能在本机齐；GitHub 关闭仍等 #52。
**GitHub：** 保持 OPEN。

{CLOSED_PRE}
{PACK}
#52 的前置已满足，**尚未执行**关票序列。#18 要等 `#20–#24` 全部 CLOSED 且评论可见后再关。

#24 判定 Status（2026-08-16T14:23:31Z）：2356 / 110 / `complete=false` / 493.768s。
#49 后续三次冷启动（2026-08-17）：2383 / 116 / 189.2–181.6s，未达 60s。不要用后者覆盖 #24 的关票计数。

{LEFTOVER}

{FOOTER}
"""

comments[20] = f"""## 状态回写（2026-08-17 续）

**实现关口：** DONE。
**GitHub：** 保持 OPEN。关闭走 #52，现可启动、尚未执行。

受管中间层转发 `$LASTEXITCODE`。`leaf-delete-failed` 经完整 `.cmd` 链为非零；缺确认 Archive 仍是 exit 0。非零主证据已在默认分支：`reports/safe-tree-delete-issue55-20260816/leaf-delete-failed.json`。

{CLOSED_PRE}

{FOOTER}
"""

comments[21] = f"""## 状态回写（2026-08-17 续）

**实现关口：** DONE。
**GitHub：** 保持 OPEN。关闭走 #52，现可启动、尚未执行。

**非零主证据只有这一条，且已在默认分支 `6937642`：**

`reports/safe-tree-delete-issue55-20260816/leaf-delete-failed.json`

回读：`exitCode=1`，`purged=false`，`refusalReason=leaf-delete-failed`。不能用 fixture、套件 `ok=true`、或 `revert-forwarding.json`（exit 0）冒充。

{FOOTER}
"""

comments[22] = f"""## 状态回写（2026-08-17 续）

**实现关口：** DONE。
**GitHub：** 保持 OPEN。关闭走 #52，现可启动、尚未执行。

关本票须引用 #24 现役计数：**operations=2356，blocking=110**（2026-08-16T14:23:31Z）。不要用 02:17 的 2323，也不要用 #49 后来的 2383/116 覆盖本票。

`complete=false` 不是本票失败。{PACK}

{FOOTER}
"""

comments[23] = f"""## 状态回写（2026-08-17 续）

**实现关口：** DONE（只读调查，无新代码）。
**GitHub：** 保持 OPEN。关闭走 #52，现可启动、尚未执行。

52 条 both-null 保留原状。#48 观测的 42 条 purged+manual-review 继续 blocking，不要为本票 Archive。现役关票计数以 #24 为准（2356 / 110）。

{FOOTER}
"""

comments[24] = f"""## 状态回写（2026-08-17 续）

**实现关口：** DONE（本票 live Status 仍以 2026-08-16T14:23:31Z 为准）。
**GitHub：** 保持 OPEN。关闭走 #52，现可启动、尚未执行。

本票数字不变：operations=**2356**，blocking=**110**，`complete=false`，墙钟 **493.768s**。utf8 SHA `3dc6070797d4b99403d0e91ab96c97841d6c6a4bcf3f69ffe48199cbdfc94efe`（工作树 CRLF；默认分支 LF 归一化后内容一致）。

后续 #49 三次冷启动是另一条线：2383 / 116 / 189–182s，未达 60s。**不要**用 #49 覆盖本票关票计数。#26–#43 仍不覆盖 Status 冷启动。

{LEFTOVER}

{FOOTER}
"""

comments[26] = f"""## 状态回写（2026-08-17 续）

**实现关口：** `DONE_WITH_CONCERNS`（无新测）。
**GitHub：** 保持 OPEN。实现仍在工作树，未进默认分支。

生产 Plan→Apply→Purge 仍是 #36 = **1.02x**、#42 = **0.962x**，未达票面 4–6x。生产 Purge 未接 `ParallelPurgeCoordinator`。#40 夹具 4.48x 不是删除加速。

#49 是 Status 冷启动，不在本史诗。#54 已 CLOSED。

{FOOTER}
"""

comments[32] = f"""## 状态回写（2026-08-17 续）

**实现关口：** `DONE_WITH_CONCERNS`。10k×4KB Apply = **0.868x**。未进默认分支。保持 OPEN。

{FOOTER}
"""

comments[33] = f"""## 状态回写（2026-08-17 续）

**实现关口：** `DONE_WITH_CONCERNS`。10k×4KB Purge = **0.921x**。生产 Purge 仍走 HostSafety。未进默认分支。保持 OPEN。

{FOOTER}
"""

comments[34] = f"""## 状态回写（2026-08-17 续）

**实现关口：** DONE。uncertain 不得收成 `purged`。未进默认分支。保持 OPEN。

{FOOTER}
"""

comments[35] = f"""## 状态回写（2026-08-17 续）

**实现关口：** waiver。FAT32/网络实卷未提权。保持 OPEN。关票仍要另授 close。

{FOOTER}
"""

comments[36] = f"""## 状态回写（2026-08-17 续）

**实现关口：** `DONE_WITH_CONCERNS`。10k×160KiB = **1.02x**，未达 3x。未进默认分支。保持 OPEN。

{FOOTER}
"""

comments[37] = f"""## 状态回写（2026-08-17 续）

**实现关口：** `DONE_WITH_CONCERNS`。批量验证已接，删除仍 HostSafety。10k = **1.02x / 0.964x**。未进默认分支。保持 OPEN。

{FOOTER}
"""

comments[38] = f"""## 状态回写（2026-08-17 续）

**实现关口：** DONE。`ThreadJournalWriter` 未接生产 Purge。未进默认分支。保持 OPEN。

{FOOTER}
"""

comments[39] = f"""## 状态回写（2026-08-17 续）

**实现关口：** `DONE_WITH_CONCERNS`。coordinator 仅夹具；生产 Purge 未接线。未进默认分支。保持 OPEN。

{FOOTER}
"""

comments[40] = f"""## 状态回写（2026-08-17 续）

**实现关口：** `DONE_WITH_CONCERNS`。夹具 DOP4=**4.48x**，不是生产删除加速。未进默认分支。保持 OPEN。

{FOOTER}
"""

comments[41] = f"""## 状态回写（2026-08-17 续）

**实现关口：** `DONE_WITH_CONCERNS`。夹具 journal overhead **18.659%**，未达 <10%。未进默认分支。保持 OPEN。

{FOOTER}
"""

comments[42] = f"""## 状态回写（2026-08-17 续）

**实现关口：** `DONE_WITH_CONCERNS`。生产 10k×4KB = **0.962x**，未达 4x/6x。未进默认分支。保持 OPEN。

{LEFTOVER}

{FOOTER}
"""

comments[43] = f"""## 状态回写（2026-08-17 续）

**实现关口：** `DONE_WITH_CONCERNS`。操作者指南已写实测 1.02x / 0.962x。未进默认分支。保持 OPEN。

{FOOTER}
"""

comments[44] = f"""## 状态回写（2026-08-17 续）

**实现关口：** DONE（本机测试）。guard pin `85d78b85…`。未 commit。保持 OPEN。

{FOOTER}
"""

comments[45] = f"""## 状态回写（2026-08-17 续）

**GitHub 关闭：** 仍不可关。四个直属子票现为 #47 CLOSED、#50 CLOSED、#52 OPEN、#53 OPEN。须等 #52 与 #53 也 `CLOSED` 且 `state_reason=completed`。

{PACK}
#52 前置已齐，**尚未执行** `#20–#24` / #18 关票序列。本票不关、不改 checkbox。

{LEFTOVER}

{FOOTER}
"""

comments[46] = f"""## 状态回写（2026-08-17 续）

**实现关口：** DONE（Reminder 本机绿）。pin `85d78b85…`。未 commit。保持 OPEN。

{FOOTER}
"""

comments[48] = f"""## 状态回写（2026-08-17 续）

**实现关口：** DONE。保持 OPEN。有意不在 #52 / #45 关票序列里关闭。

42 条 `purged` + `manual-review` 仍是观测成功，必须继续 blocking。#49 三次冷启动仍看到这 42 条。不要 Archive。

{FOOTER}
"""

comments[49] = f"""## 状态回写（2026-08-17 续）

**实现关口：** `DONE_WITH_CONCERNS`。`metTarget=false`。
**GitHub：** 保持 OPEN。未 commit。

三次独立冷启动（live `.cmd -Mode Status -Json`，每次新 pwsh 7.6.4）：

| 次 | 墙钟 | elapsedMs | operations | entriesScanned | bytesHashed |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | **189.179s** | 187074 | 2383 | 3539 | 757MB |
| 2 | **184.361s** | 182578 | 2383 | 3539 | 757MB |
| 3 | **181.586s** | 179135 | 2383 | 3539 | 757MB |

对照 #24：493.768s / 2356 / 6622 / 1.81GB。归档认证降到亚秒，仍做 marker 内容 + plan/tx SHA/identity + 现场 namespace。同一 Status 调用内树缓存**不是** Apply/Purge `SessionHashCache`。未归档整棵 `treeManifest` `ConvertFrom-Json` 仍约 160s，不能跳过认证再砍。

#48 purged+MR 仍 42。leftover 仍 `purge-resumable`、不在 blocking。未用 VSS。

证据：`reports/safe-tree-delete-issue49-20260817/`（工作树，未进默认分支）。

{LEFTOVER}

{FOOTER}
"""

comments[51] = f"""## 状态回写（2026-08-17 续）

**实现关口：** DONE（Cleanup 真超时本机绿）。pin `85d78b85…`。未 commit。保持 OPEN。

{FOOTER}
"""

comments[52] = f"""## 状态回写（2026-08-17 续）

**前置：** #47 与 #50 已 CLOSED；证据可从默认分支 `6937642` 读取。
**本票：** **可以启动，尚未执行。** 保持 OPEN。

将执行顺序仍是 `#19→#22→#23→#24`、`#20→#21`、`#21+#24→#18`，然后自关。#21 只引 `reports/safe-tree-delete-issue55-20260816/leaf-delete-failed.json` exit 1。不关 #45。#48 / #49 有意保持 OPEN。

本条不是关票序列本身。草稿仍在 `reports/safe-tree-delete-issue52-20260817/`（工作树）。

{FOOTER}
"""

comments[53] = f"""## 状态回写（2026-08-17 续）

**实现关口：** 未到执行窗口。
**GitHub：** 保持 OPEN。

须等 #52 按序关闭 #20–#24 与 #18 之后，再同步 tracker 并自关。#45 由父流程最后关。#52 现可启动、尚未执行。

{FOOTER}
"""

for number, body in comments.items():
    path = ROOT / f"comment-{number}.md"
    path.write_text(body.rstrip() + "\n", encoding="utf-8")
    print(f"wrote {path.name}")
print(f"total={len(comments)}")
